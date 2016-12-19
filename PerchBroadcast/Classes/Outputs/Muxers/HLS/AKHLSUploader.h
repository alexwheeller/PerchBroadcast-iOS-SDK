//
//  AKHLSUploader.h
//  Pods
//
//  Created by AK on 16/12/2016.
//
//

#import <Foundation/Foundation.h>
#import "KFDirectoryWatcher.h"
#import "KFHLSManifestGenerator.h"
#import "BroadcastAPIClient.h"
#import "BroadcastStream.h"
#import "KFHLSUploader.h"

@class KFS3Stream;


@interface AKHLSUploader : NSObject <KFDirectoryWatcherDelegate>

@property (nonatomic, weak) id<KFHLSUploaderDelegate> delegate;
@property (readonly, nonatomic, strong) NSString *directoryPath;
@property (nonatomic) dispatch_queue_t scanningQueue;
@property (nonatomic) dispatch_queue_t callbackQueue;
@property (nonatomic, strong) id<BroadcastStream> stream;

- (id) initWithDirectoryPath:(NSString*)directoryPath stream:(id<BroadcastStream>)stream;
- (void) finishedRecording;

- (NSURL*) manifestURL;

@end
