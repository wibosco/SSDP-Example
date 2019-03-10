//
//  SSDPSearchSession.swift
//  SSDP-Example
//
//  Created by William Boles on 17/02/2019.
//  Copyright © 2019 William Boles. All rights reserved.
//

import Foundation
import Socket
import os

enum SSDPSearchSessionError: Error {
    case addressCreationFailure
    case searchAborted(Error)
}

protocol SSDPSearchSessionDelegate: class {
    func didReceiveSearchResponse(_ response: SSDPSearchResponse)
    func didStopSearch(with error: SSDPSearchSessionError)
}

class SSDPSearchSession {
    weak var delegate: SSDPSearchSessionDelegate?
    
    private let socket: Socket
    private let configuration: SSDPSearchSessionConfiguration
    private var isListening = false
    private var respondedDevices = [SSDPSearchResponse]()
    private let searchQueue = DispatchQueue(label: "com.williamboles.searchqueue", attributes: .concurrent)
    private let processingQueue = DispatchQueue(label: "com.williamboles.processingqueue")
    private var broadcastTimer: Timer?
    private var finalBroadcastTimer: Timer?
    
    // MARK: - Init
    
    init?(configuration: SSDPSearchSessionConfiguration) {
        guard let socket = try? Socket.create(type: .datagram, proto: .udp) else {
            return nil
        }
        self.socket = socket
        self.configuration = configuration
    }
    
    // MARK: - Broadcast
    
    func start() {
        prepareSocketForResponses()
        broadcastMultipleMulticastSearchRequests()
    }
    
    private func broadcastMultipleMulticastSearchRequests() {
        let searchMessage = self.searchMessage()
        let broadcastTimeInterval = configuration.maximumWaitResponseTime
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: broadcastTimeInterval, repeats: true, block: { [weak self] (timer) in
            self?.writeToSocket(searchMessage)
        })
        broadcastTimer?.fire()
        
        let finalBroadcastTimeInterval = configuration.searchTimeout - configuration.maximumWaitResponseTime
        finalBroadcastTimer = Timer.scheduledTimer(withTimeInterval: finalBroadcastTimeInterval, repeats: false, block: { [weak self] (timer) in
            self?.finalBroadcastTimer?.invalidate()
            self?.broadcastTimer?.invalidate()
        })
    }
    
    // MARK: Write
    
    private func writeToSocket(_ datagram: String) {
        guard let address = Socket.createAddress(for: configuration.host, on: Int32(configuration.port)) else {
            handleError(SSDPSearchSessionError.addressCreationFailure)
            return
        }
        
        do {
            os_log(.info, "Writing datagram to socket: \r%{public}@", datagram)
            try socket.write(from: datagram, to: address)
        } catch {
            handleError(error)
        }
    }
    
    private func searchMessage() -> String {
        // Each line must end in `\r\n`
        return "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: \(configuration.host):\(configuration.port)\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "ST: \(configuration.searchTarget)\r\n" +
        "MX: \(Int(configuration.maximumWaitResponseTime))\r\n\r\n"
    }
    
    // MARK: - Read
    
    private func prepareSocketForResponses() {
        searchQueue.async() { [weak self] in
            self?.isListening = true
            self?.readResponse() // contains blocking call
        }
    }
    
    private func readResponse() {
        defer {
            if isListening {
                readResponse()
            }
        }
        
        do {
            var data = Data()
            let (bytesRead, _) = try socket.readDatagram(into: &data) //blocking call
            
            processingQueue.sync {
                guard bytesRead > 0,
                    let searchResponse = SSDPSearchResponse(data: data),
                    (searchResponse.searchTarget.contains(configuration.searchTarget) || configuration.searchTarget == "ssdp:all"),
                    !respondedDevices.contains(searchResponse) else {
                        return
                }
                
                respondedDevices.append(searchResponse)
                
                delegate?.didReceiveSearchResponse(searchResponse)
            }
        } catch {
            if isListening {
                handleError(error)
            }
        }
    }
    
    private func handleError(_ error: Error) {
        os_log(.error, "SSDP discovery error: %{public}@", error.localizedDescription)
        stop()
        let wrappedError = SSDPSearchSessionError.searchAborted(error)
        delegate?.didStopSearch(with: wrappedError)
    }
    
    // MARK: - Stop
    
    func stop() {
        os_log(.info, "SSDP search session is closing")
        finalBroadcastTimer?.invalidate()
        finalBroadcastTimer = nil
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        isListening = false
        socket.close()
    }
}
