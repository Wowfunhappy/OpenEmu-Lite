#import "OESaveState.h"
#import "OERom.h"
#import "OECorePlugin.h"


NSString *const OESaveStateSuffix         = @"oesavestate";
NSString *const OESaveStateDataFile       = @"State";
NSString *const OESaveStateScreenshotFile = @"ScreenShot";

static NSString *const OESaveStateLatestVersion = @"1.0";

NSString *const OESaveStateInfoVersionKey        = @"Version";
NSString *const OESaveStateInfoNameKey           = @"Name";
NSString *const OESaveStateInfoDescriptionKey    = @"Description";
NSString *const OESaveStateInfoROMMD5Key         = @"ROM MD5";
NSString *const OESaveStateInfoCoreIdentifierKey = @"Core Identifier";
NSString *const OESaveStateInfoCoreVersionKey    = @"Core Version";
NSString *const OESaveStateInfoTimestampKey      = @"Timestamp";

NSString *const OESaveStateSpecialNamePrefix = @"OESpecialState_";
NSString *const OESaveStateAutosaveName      = @"OESpecialState_auto";
NSString *const OESaveStateQuicksaveName     = @"OESpecialState_quick";

@implementation OESaveState

#pragma mark - Factory Methods

+ (OESaveState *)saveStateWithBundleURL:(NSURL *)url
{
    if(![[url pathExtension] isEqualToString:OESaveStateSuffix])
        return nil;

    OESaveState *state = [[OESaveState alloc] init];
    [state setUrl:url];

    if(![state readFromDisk])
        return nil;

    return state;
}

+ (OESaveState *)createSaveStateNamed:(NSString *)name forRom:(OERom *)rom core:(OECorePlugin *)core withFile:(NSURL *)stateFileURL
{
    if(name == nil || [name length] == 0 || rom == nil)
        return nil;

    NSURL *dataFileURL = [stateFileURL standardizedURL];
    if(![dataFileURL checkResourceIsReachableAndReturnError:nil])
        return nil;

    // Create the bundle directory inside the ROM's save state folder
    NSString *bundleName = [NSString stringWithFormat:@"%@.%@", name, OESaveStateSuffix];
    NSURL *bundleURL = [[rom stateFolderURL] URLByAppendingPathComponent:bundleName];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;

    if(![fm createDirectoryAtURL:bundleURL withIntermediateDirectories:YES attributes:nil error:&error])
    {
        NSLog(@"Could not create save state bundle: %@", error);
        return nil;
    }

    OESaveState *state = [[OESaveState alloc] init];
    [state setUrl:bundleURL];
    [state setName:name];
    [state setRomMD5:[rom md5Hash]];
    [state setCoreIdentifier:[core bundleIdentifier]];
    [state setCoreVersion:[core version]];
    [state setTimestamp:[NSDate date]];

    if(![state writeToDisk])
    {
        NSLog(@"Could not write Info.plist for save state");
        return nil;
    }

    if(![state replaceStateFileWithFile:dataFileURL])
    {
        NSLog(@"Could not copy data file to save state bundle");
        return nil;
    }

    return state;
}

+ (NSString *)nameOfQuickSaveInSlot:(NSInteger)slot
{
    return slot == 0 ? OESaveStateQuicksaveName : [NSString stringWithFormat:@"%@%ld", OESaveStateQuicksaveName, slot];
}

#pragma mark - URLs

- (NSURL *)dataFileURL
{
    return [[self url] URLByAppendingPathComponent:OESaveStateDataFile];
}

- (NSURL *)screenshotURL
{
    return [[self url] URLByAppendingPathComponent:OESaveStateScreenshotFile];
}

- (NSURL *)infoPlistURL
{
    return [[self url] URLByAppendingPathComponent:@"Info.plist"];
}

#pragma mark - Disk Operations

- (BOOL)readFromDisk
{
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfURL:[self infoPlistURL]];
    if(infoPlist == nil)
        return NO;

    NSString *name           = [infoPlist objectForKey:OESaveStateInfoNameKey];
    NSString *romMD5         = [infoPlist objectForKey:OESaveStateInfoROMMD5Key];
    NSString *coreIdentifier = [infoPlist objectForKey:OESaveStateInfoCoreIdentifierKey];

    if(name == nil || [name length] == 0) return NO;
    if(romMD5 == nil || [romMD5 length] == 0) return NO;
    if(coreIdentifier == nil || [coreIdentifier length] == 0) return NO;

    if(![[self dataFileURL] checkResourceIsReachableAndReturnError:nil])
        return NO;

    [self setName:name];
    [self setRomMD5:romMD5];
    [self setCoreIdentifier:coreIdentifier];
    [self setCoreVersion:[infoPlist objectForKey:OESaveStateInfoCoreVersionKey]];
    [self setTimestamp:[infoPlist objectForKey:OESaveStateInfoTimestampKey]];
    [self setUserDescription:[infoPlist objectForKey:OESaveStateInfoDescriptionKey]];

    return YES;
}

- (BOOL)writeToDisk
{
    if(_name == nil || [_name length] == 0) return NO;
    if(_coreIdentifier == nil || [_coreIdentifier length] == 0) return NO;
    if(_romMD5 == nil || [_romMD5 length] == 0) return NO;

    NSMutableDictionary *infoPlist = [NSMutableDictionary dictionary];
    [infoPlist setObject:_name forKey:OESaveStateInfoNameKey];
    [infoPlist setObject:_coreIdentifier forKey:OESaveStateInfoCoreIdentifierKey];
    [infoPlist setObject:_romMD5 forKey:OESaveStateInfoROMMD5Key];
    [infoPlist setObject:OESaveStateLatestVersion forKey:OESaveStateInfoVersionKey];

    if(_userDescription) [infoPlist setObject:_userDescription forKey:OESaveStateInfoDescriptionKey];
    if(_coreVersion) [infoPlist setObject:_coreVersion forKey:OESaveStateInfoCoreVersionKey];
    if(_timestamp) [infoPlist setObject:_timestamp forKey:OESaveStateInfoTimestampKey];

    return [infoPlist writeToURL:[self infoPlistURL] atomically:YES];
}

- (BOOL)replaceStateFileWithFile:(NSURL *)stateFile
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *destURL = [self dataFileURL];

    if([destURL checkResourceIsReachableAndReturnError:nil])
        [fm removeItemAtURL:destURL error:nil];

    return [fm moveItemAtURL:stateFile toURL:destURL error:nil];
}

- (void)deleteFromDisk
{
    [[NSFileManager defaultManager] removeItemAtURL:[self url] error:nil];
}

- (BOOL)isValid
{
    return [[self dataFileURL] checkResourceIsReachableAndReturnError:nil]
        && [[self infoPlistURL] checkResourceIsReachableAndReturnError:nil]
        && _name != nil && [_name length] > 0
        && _romMD5 != nil && [_romMD5 length] > 0
        && _coreIdentifier != nil && [_coreIdentifier length] > 0;
}

#pragma mark - Display

- (NSString *)displayName
{
    if([self isSpecialState])
    {
        if([[self name] isEqualToString:OESaveStateAutosaveName])
            return @"Auto Save State";
        if([[self name] isEqualToString:OESaveStateQuicksaveName])
            return @"Quick Save State";
        return [[self name] stringByReplacingOccurrencesOfString:OESaveStateSpecialNamePrefix withString:@"Quick Save "];
    }
    return [self name];
}

- (BOOL)isSpecialState
{
    return [[self name] hasPrefix:OESaveStateSpecialNamePrefix];
}

@end
