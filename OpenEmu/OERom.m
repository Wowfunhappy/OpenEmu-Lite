#import "OERom.h"
#import "OESaveState.h"
#import "OESystemPlugin.h"
#import "NSFileManager+OEHashingAdditions.h"

@implementation OERom
{
    NSString *_md5Hash;
}

+ (OERom *)romWithURL:(NSURL *)url
{
    OERom *rom = [[OERom alloc] init];
    if(rom)
    {
        rom->_url = [url URLByStandardizingPath];
        rom->_name = [[url lastPathComponent] stringByDeletingPathExtension];
        // Strip additional extension for compound types like .p8.png
        if([[rom->_name pathExtension] length] > 0 && [[rom->_name pathExtension] length] <= 4)
        {
            NSString *possibleCompound = [NSString stringWithFormat:@"%@.%@",
                [rom->_name pathExtension], [[url pathExtension] lowercaseString]];
            // Only strip if this looks like a known compound extension
            if([possibleCompound isEqualToString:@"p8.png"])
                rom->_name = [rom->_name stringByDeletingPathExtension];
        }

        // Identify system by file extension
        // Check compound extensions first (e.g. "p8.png"), then simple extension
        NSString *filename = [[url lastPathComponent] lowercaseString];
        NSString *ext = [[url pathExtension] lowercaseString];
        for(OESystemPlugin *plugin in [OESystemPlugin allPlugins])
        {
            BOOL matched = NO;
            for(NSString *suffix in [plugin supportedTypeExtensions])
            {
                if([suffix rangeOfString:@"."].location != NSNotFound)
                {
                    // Compound extension: check if filename ends with it
                    if([filename hasSuffix:suffix])
                    {
                        matched = YES;
                        break;
                    }
                }
                else if([ext isEqualToString:suffix])
                {
                    matched = YES;
                    break;
                }
            }
            if(matched)
            {
                rom->_systemPlugin = plugin;
                break;
            }
        }
    }
    return rom;
}

- (NSString *)md5Hash
{
    if(_md5Hash == nil)
    {
        NSString *md5 = nil, *crc = nil;
        [[NSFileManager defaultManager] hashFileAtURL:_url md5:&md5 crc32:&crc error:nil];
        _md5Hash = md5;
    }
    return _md5Hash;
}

- (NSURL *)stateFolderURL
{
    NSString *basePath = [@"~/Library/Application Support/OpenEmu/Save States" stringByExpandingTildeInPath];
    NSString *folderPath = [basePath stringByAppendingPathComponent:[self md5Hash]];
    return [NSURL fileURLWithPath:folderPath isDirectory:YES];
}

- (OESaveState *)autosaveState
{
    return [self saveStateWithName:OESaveStateAutosaveName];
}

- (OESaveState *)saveStateWithName:(NSString *)name
{
    NSURL *stateFolderURL = [self stateFolderURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *contents = [fm contentsOfDirectoryAtURL:stateFolderURL
                          includingPropertiesForKeys:nil
                                             options:NSDirectoryEnumerationSkipsHiddenFiles
                                               error:nil];

    for(NSURL *bundleURL in contents)
    {
        if(![[bundleURL pathExtension] isEqualToString:OESaveStateSuffix])
            continue;

        OESaveState *state = [OESaveState saveStateWithBundleURL:bundleURL];
        if(state && [[state name] isEqualToString:name])
            return state;
    }
    return nil;
}

- (OESaveState *)quickSaveStateInSlot:(NSInteger)slot
{
    NSString *name = [OESaveState nameOfQuickSaveInSlot:slot];
    return [self saveStateWithName:name];
}

@end
