%% The Vienna 5G Link Level Simulator v1.1
% www.tc.tuwien.ac.at/vccs
% Please refer to the user manual to get familiar with the simulator structure and mechanics. 
% For any questions, consider our forum www.tc.tuwien.ac.at/forum.

% Main simulator script

close all;
clear;
clc;

%% Setup
% select scenario
simulationScenario = 'LTEAcompliant';           % select a simulation scenario:
                                                % 'genericScenario'
                                                % 'LTEAcompliant'
                                                % 'multiLink'
                                                % 'flexibleNumerology'
                                                % 'NOMA'
                                                                             
% load parameters according to scenario                                               
simParams = Parameters.SimulationParameters( simulationScenario );

% generate network topology and links between nodes
[Links, BS, UE] = Topology.getTopology(simParams);

nBS         = length(BS);
nUE         = length(UE);
dimLinks    = length(Links);
nFrames     = simParams.simulation.nFrames;

% initialize result variables
perSweepResults         = cell(length(simParams.simulation.sweepValue), nFrames);
simResults              = cell(1, length(simParams.simulation.sweepValue));
averageFrameDuration    = 0;

%% Simulation loop
startTime   = tic;
myCluster   = parcluster('local');
NumWorkers  = myCluster.NumWorkers;
fprintf(['------- Started -------', '\n']);

% loop over sweep parameter
for iSweep = 1:length(simParams.simulation.sweepValue) % this may be 'for' or 'parfor'
    % update sweep value
    simParams.UpdateSweepValue(iSweep); %#ok
    
    % based on the updated sweep parameter, regenerate the network
    [Links, BS, UE] = Topology.getTopology(simParams);

    % Objects initialization should be peformed here
    Links = simParams.initializeLinks(Links, BS, UE); %#ok
    
    % save average frame duration
    if iSweep == 1
        averageFrameDuration(iSweep) = simParams.simulation.averageFrameDuration;
    end
    
    % Prepare per sweep value results
    perSweepResults = cell(dimLinks, dimLinks, nFrames);
    
    for iFrame = 1:nFrames
        % link adaptation
        % update all links
        nBS = length( BS );
        L   = length(Links);
        for iBS = 1:nBS
            for iLink = 1:L
                % Downlink
                if simParams.simulation.simulateDownlink && ~isempty(Links{BS{iBS}.ID, iLink}) && strcmp(Links{BS{iBS}.ID, iLink}.Type, 'Primary')
                    Links{BS{iBS}.ID, iLink}.updateLink( simParams, Links, iFrame );
                elseif simParams.simulation.simulateDownlink && ~isempty(Links{BS{iBS}.ID, iLink}) && strcmp(Links{BS{iBS}.ID, iLink}.Type, 'Interference')
                    Links{BS{iBS}.ID, iLink}.Channel.NewRealization(iFrame);
                end
                % Uplink
                if simParams.simulation.simulateUplink && ~isempty(Links{iLink, BS{iBS}.ID}) && strcmp(Links{iLink, BS{iBS}.ID}.Type, 'Primary')
                    Links{iLink, BS{iBS}.ID}.updateLink( simParams, Links,iFrame );
                elseif simParams.simulation.simulateUplink && ~isempty(Links{iLink, BS{iBS}.ID}) && strcmp(Links{iLink, BS{iBS}.ID}.Type, 'Interference')
                    Links{iLink, BS{iBS}.ID}.Channel.NewRealization(iFrame);
                end
            end
        end
        
        %% Downlink
        if simParams.simulation.simulateDownlink
        % All BSs generate their transmit signal for this frame
            for iBS = 1:nBS
                BS{iBS}.generateTransmitSignal(Links);
            end
            
            for iUE = 1:nUE
                UEID = UE{iUE}.ID;
                primaryLink = Links{UE{iUE}.TransmitBS(1), UEID};             
                if primaryLink.isScheduled
                    primaryLink.generateReceiveSignal();
                    UETotalSignal = primaryLink.ReceiveSignal;
                    
                    % % 4.2 用保存的信号文件作为接收机输入
                    % UETotalSignal = primaryLink.TransmitSignal;

                    % Collect signals from all other BSs
                    for iBS = 2:length(UE{iUE}.TransmitBS)
                        currentLink = Links{UE{iUE}.TransmitBS(iBS), UEID};
                        currentLink.generateReceiveSignal();
                        UETotalSignal = Channel.addSignals(UETotalSignal, currentLink.ReceiveSignal);
                    end
                    % correct signal length
                    UETotalSignal = Channel.correctSignalLength(UETotalSignal, primaryLink.Modulator.WaveformObject.Nr.SamplesTotal);
                    
%                     % plot signal spectrum
%                     plot( (1:primaryLink.Modulator.WaveformObject.Nr.SamplesTotal).' /primaryLink.Modulator.WaveformObject.Nr.SamplesTotal * simParams.modulation.samplingRate, 20*log10(abs(fft(UETotalSignal))))
%                     xlabel('f in Hz');
%                     ylabel('Signal Power in dB');
%                     xlim([0 6e6]);
%                     ylim([-150 -50]);
%                     grid on;
%                     print('-dpdf','PSD_comp_','-bestfit')
                    

                    % add noise
                    UETotalSignal = UETotalSignal + Channel.AWGN( simParams.phy.noisePower, length(UETotalSignal), UE{iUE}.nAntennas );
                    
                    % process received signal
                    UE{iUE}.processReceiveSignal(UETotalSignal, Links, simParams);

                    % Collect the results which is now stored in the primary link
                    primaryLink.calculateSNR(simParams.constants.BOLTZMANN, simParams.phy.temperature);
                    perSweepResults{UE{iUE}.TransmitBS(1), UEID, iFrame} = primaryLink.getResults(simParams.simulation.saveData);
                end
            end
            
         end 
         %% Uplink
         if simParams.simulation.simulateUplink
            % All UEs generate their transmit signal for this frame
            for iUE = 1:nUE
                UE{iUE}.generateTransmitSignal(Links);
            end
            for iBS = 1:nBS
                BSID = BS{iBS}.ID;
                BSTotalSignal = [];
                % Collect signals from all users transmitting to this BS
                % (both primary and interfering users)
                for iUE = 1:length(BS{iBS}.TransmitUE)
                    currentLink = Links{BS{iBS}.TransmitUE(iUE), BSID};
                    if strcmp(currentLink.Type, 'Primary')
                        signalLength = currentLink.Modulator.WaveformObject.Nr.SamplesTotal;
                    end
                    if currentLink.isScheduled
                        currentLink.generateReceiveSignal();                      
                        BSTotalSignal = Channel.addSignals(BSTotalSignal, currentLink.ReceiveSignal);
                    end
                end
                % correct signal length
                BSTotalSignal = Channel.correctSignalLength(BSTotalSignal, signalLength);      
                
                % add noise
                BSTotalSignal = BSTotalSignal + Channel.AWGN( simParams.phy.noisePower, length(BSTotalSignal), BS{iBS}.nAntennas );
                
                % process received signal
                BS{iBS}.processReceiveSignal(BSTotalSignal, Links, simParams);

                % Collect the results
                for iUE = 1:length(BS{iBS}.TransmitUE)
                    currentLink = Links{BS{iBS}.TransmitUE(iUE), BSID};
                    if currentLink.isScheduled && strcmp(currentLink.Type, 'Primary')
                        currentLink.calculateSNR(simParams.constants.BOLTZMANN, simParams.phy.temperature);
                        perSweepResults{BS{iBS}.TransmitUE(iUE), BSID, iFrame} = currentLink.getResults(simParams.simulation.saveData);
                    end
                end  
            end
        end
        %% Device-to-Device
%         if simParams.simulation.simulateD2D
%            % Not yet implemented, but it can be done in a similar fashion
%         end

        %% Time calculation
        % Some basic time calculation.
        intermediateTime = tic;
        if mod(iFrame, 20) == 0
            fprintf('Sweep: %i/%i, Frame: %i/%i, approx. %.0fs left\n', iSweep,length(simParams.simulation.sweepValue),iFrame,nFrames, double(intermediateTime-startTime)*1e-6*(nFrames*length(simParams.simulation.sweepValue)-(iFrame+(iSweep-1)*nFrames))/(iFrame+(iSweep-1)*nFrames));
        end
    end % for iFrame
    simResults{iSweep} = perSweepResults;
end % parfor iSweep

%% post process simulation results
if simParams.simulation.simulateDownlink
    downlinkResults = Results.SimulationResults( nFrames, length(simParams.simulation.sweepValue), nBS, nUE, averageFrameDuration, 'downlink' );
    downlinkResults.collectResults( simResults, UE );
    downlinkResults.postProcessResults();
    % plot results
    if sum(simParams.simulation.plotResultsFor) ~= 0
        % Results.plotResults( downlinkResults, 'downlink', simParams, UE, BS );
    end
end
if simParams.simulation.simulateUplink
    uplinkResults = Results.SimulationResults( nFrames, length(simParams.simulation.sweepValue), nBS, nUE, averageFrameDuration, 'uplink' );
    uplinkResults.collectResults( simResults, UE );
    uplinkResults.postProcessResults();
    % plot results
    if sum(simParams.simulation.plotResultsFor) ~= 0
        Results.plotResults( uplinkResults, 'uplink', simParams, UE, BS );
    end
end

%% save results
% generate timestamp
tmpStr = datestr(now);
tmpStr = strrep(tmpStr,':','_');
timeStamp = strrep(tmpStr,' ','_');
% save results (complete workspace)
save(['./results/results_',timeStamp]);

fprintf(['------- Done -------', '\n']);
toc(startTime);

% % 1.2 绘制柱状图，数据在downlinkResults.userResults.BERCoded
% subplot(2,2,1)
% bar(downlinkResults.userResults.BERCoded.values)
% xlabel('frame number')
% ylabel('')
% title('BER Coded')

% subplot(2,2,2)
% bar(downlinkResults.userResults.BERUncoded.values)
% xlabel('frame number')
% ylabel('')
% title('BER Uncoded')

% subplot(2,2,3)
% bar(downlinkResults.userResults.FER.values)
% xlabel('frame number')
% ylabel('')
% title('FER')

% subplot(2,2,4)
% bar(downlinkResults.userResults.throughput.values)
% xlabel('frame number')
% ylabel('')
% title('throughput')

% % 2.1 绘制发送信号星座图
% figure
% scatter(real(Links{1,2}.TransmitSymbols{1,1}), imag(Links{1,2}.TransmitSymbols{1,1}), '.')
% % 2.2 绘制接收信号星座图
% figure
% scatter(real(UETotalSignal(:, 1)), imag(UETotalSignal(:, 1)), '.')

% % 3.1 绘制发送信号时域波形
% figure
% subplot(2,1,1)
% plot(abs(Links{1,2}.TransmitSymbols{1,1}))
% title("发送信号幅值")
% subplot(2,1,2)
% plot(angle(Links{1,2}.TransmitSymbols{1,1}))
% title("发送信号相角")

% % 3.2 绘制接收信号时域波形
% figure
% subplot(2,1,1)
% plot(abs(UETotalSignal(:, 1)))
% title("接收信号幅值")
% subplot(2,1,2)
% plot(angle(UETotalSignal(:, 1)))
% title("接收信号相角")

% % 1.1 绘制发送信号功率谱
% figure
% [pxx, f] = pwelch(Links{1,2}.TransmitSignal(:, 1), [], [], [], simParams.modulation.samplingRate);
% plot(f, 10*log10(pxx))
% title("发送信号功率谱")

% % 1.2 绘制接收信号功率谱
% figure
% [pxx, f] = pwelch(UETotalSignal(:, 1), [], [], [], simParams.modulation.samplingRate);
% plot(f, 10*log10(pxx))
% title("接收信号功率谱")

% % 保存发射信号
% var4_1 = Links{1,2}.TransmitSignal(:, 1);
% save('TransmitSignal.mat', 'var4_1')

% exp04-03 绘制每个基站所有用户接收信号星座图，吞吐量，真实信道，频域信道估计
for iBS = 1:nBS
    BSID = BS{iBS}.ID;
    for iUE = 1:nUE
        UEID = UE{iUE}.ID;

        if isempty(Links{BSID, UEID}.Modulator)
            continue
        end
        % % 绘制接收信号星座图
        % figure(iBS*100+iUE*10+1)
        % scatter(real(Links{BSID, UEID}.Modulator.rxData_(:, 1)), imag(Links{BSID, UEID}.Modulator.rxData_(:, 1)), '.')
        % xlim([-1.5 1.5])
        % ylim([-1.5 1.5])

        % 绘制误码率
        figure(iBS*100+iUE*10+1)
        bar(downlinkResults.userResults(iUE).BERUncoded.values)
        xlabel('frame number')
        ylabel('BER Uncoded')
        title(['BS ', num2str(iBS), ' User ', num2str(iUE), ' Coded BER'])

        % 绘制吞吐量
        figure(iBS*100+iUE*10+2)
        bar(downlinkResults.userResults(iUE).throughput.values)
        xlabel('frame number')
        ylabel('throughput')
        title(['BS ', num2str(iBS), ' User ', num2str(iUE)])

        % 绘制接收信号功率谱
        figure(iBS*100+iUE*10+3)
        [pxx, f] = pwelch(Links{BSID, UEID}.TransmitSignal(:, 1), [], [], [], simParams.modulation.samplingRate);
        plot(f, 10*log10(pxx))
        title(['BS ', num2str(iBS), ' User ', num2str(iUE), ' received signal power spectrum'])

        % 绘制接收信号时域波形
        t = 0:1/simParams.modulation.samplingRate:(length(Links{BSID, UEID}.TransmitSignal(:, 1))-1)/simParams.modulation.samplingRate;
        figure(iBS*100+iUE*10+4)
        subplot(2,1,1)
        plot(t, abs(Links{BSID, UEID}.TransmitSignal(:, 1)))
        title(['BS ', num2str(iBS), ' User ', num2str(iUE), ' received signal amplitude'])
        xlabel('time/s')
        ylabel('amplitude')
        subplot(2,1,2)
        plot(t, angle(Links{BSID, UEID}.TransmitSignal(:, 1)))
        title(['BS ', num2str(iBS), ' User ', num2str(iUE), ' received signal phase'])
        xlabel('time/s')
        ylabel('phase')

        % % 绘制真实信道
        % figure(iBS*100+iUE*10+3)
        % channel = Links{BSID, UEID}.Modulator.Channel(:,:,1);
        % x = 1:1:size(channel, 1);
        % y = 1:1:size(channel, 2);
        % [X, Y] = meshgrid(x, y);
        % surf(X, Y, 10*log(abs(channel')))
        % xlabel('subcarrier')
        % ylabel('OFDM symbol')
        % zlabel('channel gain')
        % title(['BS ', num2str(iBS), ' User ', num2str(iUE), ' real channel'])

        % % 绘制估计信道
        % figure(iBS*100+iUE*10+4)
        % channel = Links{BSID, UEID}.Modulator.perfectChannel_(:,:,1);
        % surf(X, Y, 10*log(abs(channel')))
        % xlabel('subcarrier')
        % ylabel('OFDM symbol')
        % zlabel('channel gain')
        % title(['BS ', num2str(iBS), ' User ', num2str(iUE), ' estimated channel'])
    end
end