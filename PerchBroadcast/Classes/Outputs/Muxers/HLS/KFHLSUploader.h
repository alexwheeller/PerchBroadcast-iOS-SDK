//
//  KFHLSUploader.h
//  FFmpegEncoder
//
//  Created by Christopher Ballinger on 12/20/13.
//  Copyright (c) 2013 Christopher Ballinger. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "KFDirectoryWatcher.h"
#import "KFHLSManifestGenerator.h"
#import "BroadcastAPIClient.h"
#import "BroadcastStream.h"

@class KFS3Stream, KFHLSUploader;

@protocol KFHLSUploaderDelegate <NSObject>
@optional
- (void) uploader:(NSObject*)uploader didUploadSegmentAtURL:(NSURL*)segmentURL uploadSpeed:(double)uploadSpeed numberOfQueuedSegments:(NSUInteger)numberOfQueuedSegments; //KBps
- (void) uploader:(KFHLSUploader *)uploader liveManifestReadyAtURL:(NSURL*)manifestURL;
- (void) uploader:(KFHLSUploader *)uploader vodManifestReadyAtURL:(NSURL*)manifestURL;
- (void) uploader:(KFHLSUploader *)uploader thumbnailReadyAtURL:(NSURL*)manifestURL;
- (void) uploaderHasFinished:(KFHLSUploader*)uploader;
@end

@interface KFHLSUploader : NSObject <KFDirectoryWatcherDelegate>

@property (nonatomic, weak) id<KFHLSUploaderDelegate> delegate;
@property (readonly, nonatomic, strong) NSString *directoryPath;
@property (nonatomic) dispatch_queue_t scanningQueue;
@property (nonatomic) dispatch_queue_t callbackQueue;
@property (nonatomic, strong) id<BroadcastStream> stream;
@property (nonatomic) BOOL useSSL;
@property (nonatomic, strong) KFHLSManifestGenerator *manifestGenerator;
@property (nonatomic, strong) KFHLSManifestGenerator *manifestGeneratorLive;
@property (nonatomic, strong) id<BroadcastAPIClient> apiClient;

- (id) initWithDirectoryPath:(NSString*)directoryPath stream:(id<BroadcastStream>)stream apiClient:(id<BroadcastAPIClient>)apiClient;
- (void) finishedRecording;

- (NSURL*) manifestURL;

@end
