#import <Foundation/Foundation.h>

extern NSString *const OESaveStateSuffix;
extern NSString *const OESaveStateDataFile;
extern NSString *const OESaveStateScreenshotFile;

extern NSString *const OESaveStateInfoVersionKey;
extern NSString *const OESaveStateInfoNameKey;
extern NSString *const OESaveStateInfoDescriptionKey;
extern NSString *const OESaveStateInfoROMMD5Key;
extern NSString *const OESaveStateInfoCoreIdentifierKey;
extern NSString *const OESaveStateInfoCoreVersionKey;
extern NSString *const OESaveStateInfoTimestampKey;

extern NSString *const OESaveStateSpecialNamePrefix;
extern NSString *const OESaveStateAutosaveName;
extern NSString *const OESaveStateQuicksaveName;


@class OERom, OECorePlugin;

@interface OESaveState : NSObject

+ (OESaveState *)saveStateWithBundleURL:(NSURL *)url;
+ (OESaveState *)createSaveStateNamed:(NSString *)name forRom:(OERom *)rom core:(OECorePlugin *)core withFile:(NSURL *)stateFileURL;
+ (NSString *)nameOfQuickSaveInSlot:(NSInteger)slot;

- (BOOL)readFromDisk;
- (BOOL)writeToDisk;
- (BOOL)replaceStateFileWithFile:(NSURL *)stateFile;
- (void)deleteFromDisk;
- (BOOL)isValid;

- (NSString *)displayName;
- (BOOL)isSpecialState;

@property (nonatomic, retain) NSURL *url;
@property (nonatomic, retain) NSString *name;
@property (nonatomic, retain) NSString *userDescription;
@property (nonatomic, retain) NSDate *timestamp;
@property (nonatomic, retain) NSString *coreIdentifier;
@property (nonatomic, retain) NSString *coreVersion;
@property (nonatomic, retain) NSString *romMD5;

@property (nonatomic, readonly) NSURL *dataFileURL;
@property (nonatomic, readonly) NSURL *screenshotURL;
@property (nonatomic, readonly) NSURL *infoPlistURL;

@end
