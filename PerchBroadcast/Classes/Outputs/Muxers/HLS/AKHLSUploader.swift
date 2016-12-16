//
//  AKHLSUploader.swift
//  Pods
//
//  Created by AK on 16/12/2016.
//
//

import Foundation

class Manifest {
    let kFileName = "filename"
    let kStatus = "status"
    let kDuration = "duration"
    
    var targetDuration: Int?
    var mediaSequence: Int = -1
    var version: Int = 3
    var segments: Array<[String:String]> = []
    var finished: Bool = false
    
    init(string: String) {
        let parts = string.components(separatedBy: "#EXTINF:")
        
        // process header
        parts[0].components(separatedBy: "\n").forEach {
            
            if $0.hasPrefix("#EXT-X-VERSION:") {
                self.version = Int($0.components(separatedBy: ":")[1]) ?? self.version
            }
            
            if $0.hasPrefix("#EXT-X-TARGETDURATION:") {
                self.targetDuration = Int($0.components(separatedBy: ":")[1])
            }
            
            if $0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                self.mediaSequence = Int($0.components(separatedBy: ":")[1]) ?? self.mediaSequence
            }
        }
        
        for i in 1...parts.count {
            let info = parts[i].replacingOccurrences(of: "\n", with: "").components(separatedBy: ",")
            self.segments.append([kFileName: info[1], kDuration: info[0]])
        }
    }
    
    func toString() -> String {
        var res: String = "#EXTM3U\n#EXT-X-VERSION:\(self.version)\n"
        
        if let duration = self.targetDuration {
            res += "#EXT-X-TARGETDURATION:\(duration)\n"
        }
        
        res += "#EXT-X-MEDIA-SEQUENCE:\(self.mediaSequence)\n"
        
        self.segments.forEach {
            res += "#EXTINF:\($0[kDuration]),\n\($0[kFileName])\n"
        }
        
        if finished {
            res += "#EXT-X-ENDLIST\n"
        }
        
        return res
    }
}

@objc class AKHLSUploader: NSObject, KFDirectoryWatcherDelegate {
    
    var stream: BroadcastStream
    var directoryPath: String
    var directoryWatcher: KFDirectoryWatcher?
    var s3: AWSS3
    var transferManager: AWSS3TransferManager
    
    var liveManifest: Manifest?
    
    init(directoryPath: String, stream: BroadcastStream) {
        
        self.directoryPath = directoryPath
        self.stream = stream
        
        let region = KFAWSCredentialsProvider.regionType(forRegion: stream.endpoint as! String!)
        let awsCredentialsProvider = KFAWSCredentialsProvider(endpoint: stream.endpoint as! BroadcastS3Endpoint)
        let configuration = AWSServiceConfiguration(region: region, credentialsProvider: awsCredentialsProvider)
        
        AWSS3TransferManager.register(with: configuration, forKey: "kKFS3TransferManagerKey")
        AWSS3.register(with: configuration!, forKey: "kKFS3TransferManagerKey")
        
        self.transferManager = AWSS3TransferManager.s3TransferManager(forKey: "kKFS3Key")
        self.s3 = AWSS3.s3(forKey: "kKFS3Key")
        
        super.init()
        
        self.directoryWatcher = KFDirectoryWatcher.watchFolder(withPath: directoryPath, delegate: self)
    }
    
    
    public func directoryDidChange(_ folderWatcher: KFDirectoryWatcher!) {
        let path = Bundle.main.path(forResource: self.directoryPath + "\\index", ofType: "m3u8")!
        if let contents = try? String(contentsOfFile: path, encoding: String.Encoding.utf8) {
            self.liveManifest = Manifest(string: contents)
        }
    }
}
