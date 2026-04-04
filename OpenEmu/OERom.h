#import <Foundation/Foundation.h>

@class OESystemPlugin, OESaveState;

@interface OERom : NSObject

+ (OERom *)romWithURL:(NSURL *)url;

@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) NSString *md5Hash;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) OESystemPlugin *systemPlugin;
@property (nonatomic, readonly) NSURL *stateFolderURL;

- (OESaveState *)autosaveState;
- (OESaveState *)saveStateWithName:(NSString *)name;
- (OESaveState *)quickSaveStateInSlot:(NSInteger)slot;

@end
