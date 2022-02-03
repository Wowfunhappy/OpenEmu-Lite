/*
 Copyright (c) 2009, OpenEmu Team

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEGameDocument.h"

#import "OEApplicationDelegate.h"
#import "OEAudioDeviceManager.h"
#import "OEBackgroundColorView.h"
#import "OECorePickerController.h"
#import "OECorePlugin.h"
#import "OEDBRom.h"
#import "OEDBGame.h"
#import "OEDBSaveState.h"
#import "OEDOGameCoreManager.h"
#import "OEGameCoreManager.h"
#import "OEGameView.h"
#import "OEGameViewController.h"
#import "OEHUDAlert+DefaultAlertsAdditions.h"
#import "OEHUDWindow.h"
#import "OELibraryDatabase.h"
#import "OEPopoutGameWindowController.h"
#import "OEPreferencesController.h"
#import "OESystemPlugin.h"
#import "OEThreadGameCoreManager.h"
#import "OEXPCGameCoreManager.h"
#import "NSURL+OELibraryAdditions.h"
#import "NSView+FadeImage.h"
#import "NSViewController+OEAdditions.h"

#import <objc/message.h>

NSString *const OEGameCoreManagerModePreferenceKey = @"OEGameCoreManagerModePreference";
NSString *const OEGameDocumentErrorDomain = @"OEGameDocumentErrorDomain";

#define UDDefaultCoreMappingKeyPrefix   @"defaultCore"
#define UDSystemCoreMappingKeyForSystemIdentifier(_SYSTEM_IDENTIFIER_) [NSString stringWithFormat:@"%@.%@", UDDefaultCoreMappingKeyPrefix, _SYSTEM_IDENTIFIER_]

// Helper to call a method with this signature:
// - (void)document:(NSDocument *)doc shouldClose:(BOOL)shouldClose  contextInfo:(void  *)contextInfo
#define CAN_CLOSE_REPLY ((void(*)(id, SEL, NSDocument *, BOOL, void *))objc_msgSend)

typedef enum : NSUInteger
{
    OEEmulationStatusNotSetup,
    OEEmulationStatusSetup,
    OEEmulationStatusStarting,
    OEEmulationStatusPlaying,
    OEEmulationStatusPaused,
    OEEmulationStatusTerminating,
} OEEmulationStatus;

@interface OEGameDocument () <OEGameCoreDisplayHelper>
{
    OEGameCoreManager  *_gameCoreManager;
    OESystemController *_gameSystemController;

    NSTimer            *_systemSleepTimer;

    OEEmulationStatus   _emulationStatus;
    OEDBSaveState      *_saveStateForGameStart;
    NSDate             *_lastPlayStartDate;
    BOOL                _isMuted;
    //BOOL                _pausedByGoingToBackground;
    BOOL                _isTerminatingEmulation;
}

@property OEGameViewController *gameViewController;
@property NSViewController *viewController;

@end

@implementation OEGameDocument

- (id)init
{
    if((self = [super init]) != nil)
    {
        _gameViewController = [[OEGameViewController alloc] init];
        [[self gameViewController] setDocument:self];
    }

    return self;
}

- (id)initWithRom:(OEDBRom *)rom core:(OECorePlugin *)core error:(NSError **)outError
{
    if(!(self = [self init]))
        return nil;

    if(![self OE_setupDocumentWithROM:rom usingCorePlugin:core error:outError])
        return nil;

    return self;
}

- (id)initWithGame:(OEDBGame *)game core:(OECorePlugin *)core error:(NSError **)outError
{
    return [self initWithRom:[game defaultROM] core:core error:outError];
}

- (id)initWithSaveState:(OEDBSaveState *)state error:(NSError **)outError
{
    if(!(self = [self init]))
        return nil;

    if(![self OE_setupDocumentWithSaveState:state error:outError])
        return nil;

    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p, ROM: '%@', System: '%@', Core: '%@'>", [self class], self, [[[self rom] game] displayName], [_systemPlugin systemIdentifier], [_corePlugin bundleIdentifier]];
}

- (NSString *)coreIdentifier;
{
    return [[_gameCoreManager plugin] bundleIdentifier];
}

- (NSString *)systemIdentifier;
{
    return [_gameSystemController systemIdentifier];
}

- (BOOL)OE_setupDocumentWithSaveState:(OEDBSaveState *)saveState error:(NSError **)outError
{
    if(![self OE_setupDocumentWithROM:[saveState rom] usingCorePlugin:[OECorePlugin corePluginWithBundleIdentifier:[saveState coreIdentifier]] error:outError])
        return NO;

    _saveStateForGameStart = saveState;

    return YES;
}

- (BOOL)OE_setupDocumentWithROM:(OEDBRom *)rom usingCorePlugin:(OECorePlugin *)core error:(NSError **)outError
{
    NSURL *fileURL = [rom URL];

    _rom = rom;
    _romFileURL = fileURL;
    _corePlugin = core;
    _systemPlugin = [[[[self rom] game] system] plugin];
    _gameSystemController = [_systemPlugin controller];

    if(_corePlugin == nil)
        _corePlugin = [self OE_coreForSystem:_systemPlugin error:outError];
    
    if(_corePlugin == nil)
    {
        __block NSError *blockError = *outError;
        *outError = blockError;
    }

    _gameCoreManager = [self _newGameCoreManagerWithCorePlugin:_corePlugin];

    return _gameCoreManager != nil;
}

- (void)OE_setupGameCoreManagerUsingCorePlugin:(OECorePlugin *)core completionHandler:(void(^)(void))completionHandler
{
    NSAssert(core != [_gameCoreManager plugin], @"Do not attempt to run a new core using the same plug-in as the current one.");

    _emulationStatus = OEEmulationStatusNotSetup;
    [_gameCoreManager stopEmulationWithCompletionHandler:
     ^{
         _gameCoreManager = [self _newGameCoreManagerWithCorePlugin:core];
         [self setupGameWithCompletionHandler:
          ^(BOOL success, NSError *error)
          {
              if(!success)
              {
                  [self presentError:error];
                  return;
              }

              completionHandler();
          }];
     }];
}

- (OEGameCoreManager *)_newGameCoreManagerWithCorePlugin:(OECorePlugin *)corePlugin
{
    if(corePlugin == nil)
        return nil;
    
    NSString *managerClassName = [[NSUserDefaults standardUserDefaults] objectForKey:OEGameCoreManagerModePreferenceKey];

    Class managerClass = NSClassFromString(managerClassName);
    if(managerClass == [OEXPCGameCoreManager class])
    {
        if(![OEXPCGameCoreManager canUseXPCGameCoreManager])
            managerClass = [OEDOGameCoreManager class];
    }
    else if(managerClass != [OEThreadGameCoreManager class] && managerClass != [OEDOGameCoreManager class])
        managerClass = [OEXPCGameCoreManager canUseXPCGameCoreManager] ? [OEXPCGameCoreManager class] : [OEDOGameCoreManager class];

    _corePlugin = corePlugin;
    [[NSUserDefaults standardUserDefaults] setValue:[_corePlugin bundleIdentifier] forKey:UDSystemCoreMappingKeyForSystemIdentifier([self systemIdentifier])];

    NSString *path = [[self romFileURL] path];
     // if file is in an archive append :entryIndex to path, so the core manager can figure out which entry to load
    if([[self rom] archiveFileIndex])
        path = [path stringByAppendingFormat:@":%d",[[[self rom] archiveFileIndex] intValue]];

    return [[managerClass alloc] initWithROMPath:path corePlugin:_corePlugin systemController:_gameSystemController displayHelper:self];
}

- (OECorePlugin *)OE_coreForSystem:(OESystemPlugin *)system error:(NSError **)outError
{
    OECorePlugin *chosenCore = nil;
    NSArray *validPlugins = [OECorePlugin corePluginsForSystemIdentifier:[self systemIdentifier]];

    if([validPlugins count] == 0 && outError != nil)
    {
            *outError = [NSError errorWithDomain:OEGameDocumentErrorDomain
                                            code:OENoCoreError
                                        userInfo: @{
                                                    NSLocalizedFailureReasonErrorKey : OELocalizedString(@"OpenEmu could not find a Core to launch the game", @"No Core error reason."),
                                                    NSLocalizedRecoverySuggestionErrorKey : OELocalizedString(@"Please install a suitable core.", @"No Core error recovery suggestion."),
                                                    }];
        chosenCore = nil;
    }
    else if([validPlugins count] == 1)
        chosenCore = [validPlugins lastObject];
    else
    {
        NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
        NSString *coreIdentifier = [standardUserDefaults valueForKey:UDSystemCoreMappingKeyForSystemIdentifier([self systemIdentifier])];
        chosenCore = [OECorePlugin corePluginWithBundleIdentifier:coreIdentifier];
        if(chosenCore == nil)
        {
            validPlugins = [validPlugins sortedArrayUsingComparator:
                            ^ NSComparisonResult (id obj1, id obj2)
                            {
                                return [[obj1 displayName] compare:[obj2 displayName]];
                            }];

            chosenCore = [validPlugins objectAtIndex:0];
            [standardUserDefaults setValue:[chosenCore bundleIdentifier] forKey:UDSystemCoreMappingKeyForSystemIdentifier([self systemIdentifier])];
        }
    }

    return chosenCore;
}

- (void)dealloc
{
    NSURL *url = [self romFileURL];
    if([url isNotEqualTo:[[self rom] URL]])
    {
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    }
}

#pragma mark - Game Window

- (void)setGameWindowController:(NSWindowController *)value
{
    if(_gameWindowController == value)
        return;

    if(_gameWindowController != nil)
    {
        [self OE_removeObserversForWindowController:_gameWindowController];
        [self removeWindowController:_gameWindowController];
    }

    _gameWindowController = value;

    if(_gameWindowController != nil)
    {
        [self addWindowController:_gameWindowController];
        [self OE_addObserversForWindowController:_gameWindowController];
    }
}

- (void)OE_addObserversForWindowController:(NSWindowController *)windowController
{
    NSWindow *window = [windowController window];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserver:self selector:@selector(windowDidBecomeMain:) name:NSWindowDidBecomeMainNotification object:window];
    [center addObserver:self selector:@selector(windowDidResignMain:) name:NSWindowDidResignMainNotification object:window];
}

- (void)OE_removeObserversForWindowController:(NSWindowController *)windowController
{
    NSWindow *window = [windowController window];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center removeObserver:self name:NSWindowDidBecomeMainNotification object:window];
    [center removeObserver:self name:NSWindowDidResignMainNotification object:window];
}

- (void)windowDidResignMain:(NSNotification *)notification
{
    /*BOOL backgroundPause = [[NSUserDefaults standardUserDefaults] boolForKey:OEBackgroundPauseKey];
    if(backgroundPause && _emulationStatus == OEEmulationStatusPlaying)
    {
        [self setEmulationPaused:YES];
        _pausedByGoingToBackground = YES;
    }*/
}

- (void)windowDidBecomeMain:(NSNotification *)notification
{
    /*if(_pausedByGoingToBackground)
    {
        [self setEmulationPaused:NO];
        _pausedByGoingToBackground = NO;
    }*/
}

#pragma mark - Device Notifications
- (void)OE_addDeviceNotificationObservers
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(OE_didReceiveLowBatteryWarningNotification:) name:OEDeviceHandlerDidReceiveLowBatteryWarningNotification object:nil];
    [nc addObserver:self selector:@selector(OE_deviceDidDisconnectNotification:) name:OEDeviceManagerDidRemoveDeviceHandlerNotification object:nil];
}

- (void)OE_removeDeviceNotificationObservers
{
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self name:OEDeviceHandlerDidReceiveLowBatteryWarningNotification object:nil];
    [nc removeObserver:self name:OEDeviceManagerDidRemoveDeviceHandlerNotification object:nil];
}

- (void)OE_didReceiveLowBatteryWarningNotification:(NSNotification *)notification
{
    BOOL isRunning = ![self isEmulationPaused];
    [self setEmulationPaused:YES];

    OEDeviceHandler *devHandler = [notification object];
    NSString *lowBatteryString = [NSString stringWithFormat:OELocalizedString(@"The battery in device number %lu, %@, is low. Please charge or replace the battery.", @"Low battery alert detail message."), [devHandler deviceNumber], [[devHandler deviceDescription] name]];
    OEHUDAlert *alert = [OEHUDAlert alertWithMessageText:lowBatteryString
                                           defaultButton:OELocalizedString(@"Resume", nil)
                                         alternateButton:nil];
    [alert setHeadlineText:[NSString stringWithFormat:OELocalizedString(@"Low Controller Battery", @"Device battery level is low.")]];
    [alert runModal];

    if(isRunning) [self setEmulationPaused:NO];
}

- (void)OE_deviceDidDisconnectNotification:(NSNotification *)notification
{
    BOOL isRunning = ![self isEmulationPaused];
    [self setEmulationPaused:YES];

    OEDeviceHandler *devHandler = [[notification userInfo] objectForKey:OEDeviceManagerDeviceHandlerUserInfoKey];
    NSString *lowBatteryString = [NSString stringWithFormat:OELocalizedString(@"Device number %lu, %@, has disconnected.", @"Device disconnection detail message."), [devHandler deviceNumber], [[devHandler deviceDescription] name]];
    OEHUDAlert *alert = [OEHUDAlert alertWithMessageText:lowBatteryString
                                           defaultButton:OELocalizedString(@"Resume", @"Resume game after battery warning button label")
                                         alternateButton:nil];
    [alert setHeadlineText:[NSString stringWithFormat:OELocalizedString(@"Device Disconnected", @"A controller device has disconnected.")]];
    [alert runModal];

    if(isRunning) [self setEmulationPaused:NO];
}

- (void)showInSeparateWindowInFullScreen:(BOOL)fullScreen;
{
    //OEHUDWindow *window = [[OEHUDWindow alloc] initWithContentRect:NSZeroRect];
    //OEPopoutGameWindowController *windowController = [[OEPopoutGameWindowController alloc] initWithWindow:window];
    
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:
                        NSTitledWindowMask | NSResizableWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask

                                                     backing:NSBackingStoreBuffered defer:NO];
    OEPopoutGameWindowController *windowController = [[OEPopoutGameWindowController alloc] initWithWindow:window];

    //[windowController setWindowFullScreen:fullScreen];
    [self setGameWindowController:windowController];
    [self showWindows];

    [self setEmulationPaused:NO];
}

- (NSString *)displayName
{
    // If we do not have a title yet, return an empty string instead of [super displayName].
    // The latter uses Cocoa document architecture and relies on documents having URLs,
    // including untitled (new) documents.
    NSString *displayName = [[[self rom] game] displayName];
#if DEBUG_PRINT
    //displayName = [displayName stringByAppendingString:@" (DEBUG BUILD)"];
#endif

    return displayName ? : @"";
}

#pragma mark - OS Sleep Handling

- (void)preventSystemSleepTimer:(NSTimer *)aTimer;
{
    UpdateSystemActivity(OverallAct);
}

- (void)enableOSSleep
{
    if(_systemSleepTimer == nil) return;

    [_systemSleepTimer invalidate];
    _systemSleepTimer = nil;
}

- (void)disableOSSleep
{
    if(_systemSleepTimer != nil) return;

    _systemSleepTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(preventSystemSleepTimer:) userInfo:nil repeats:YES];
}

#pragma mark - NSDocument Stuff

- (NSData *)dataOfType:(NSString *)typeName error:(NSError **)outError
{
    DLog(@"%@", typeName);

    if(outError != NULL)
        *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:unimpErr userInfo:NULL];
    return nil;
}

- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
    DLog(@"%@", absoluteURL);
    DLog(@"%@", typeName);
    if([typeName isEqualToString:@"org.openemu.savestate"])
    {
        NSManagedObjectContext *context = [[OELibraryDatabase defaultDatabase] mainThreadContext];
        OEDBSaveState *state = [OEDBSaveState updateOrCreateStateWithURL:absoluteURL inContext:context];
        if(state && [self OE_setupDocumentWithSaveState:state error:outError])
            return YES;
        return NO;
    }

    NSString *romPath = [absoluteURL path];
    if(![[NSFileManager defaultManager] fileExistsAtPath:romPath])
    {
        if(outError != NULL)
        {
            *outError = [NSError errorWithDomain:OEGameDocumentErrorDomain
                                            code:OEFileDoesNotExistError
                                        userInfo:
                         [NSDictionary dictionaryWithObjectsAndKeys:
                          OELocalizedString(@"The file you selected doesn't exist", @"Inexistent file error reason."),
                          NSLocalizedFailureReasonErrorKey,
                          OELocalizedString(@"Choose a valid file.", @"Inexistent file error recovery suggestion."),
                          NSLocalizedRecoverySuggestionErrorKey,
                          nil]];
        }
        DLog(@"File does not exist");

        return NO;
    }

    // get rom by path
    if(![absoluteURL isFileURL])
    {
        DLog(@"URLs that are not file urls are currently not supported!");
        // TODO: Handle URLS, by downloading to temp folder
    }

    OEDBGame *game = [OEDBGame gameWithURL:absoluteURL inDatabase:[OELibraryDatabase defaultDatabase] error:outError];
    if(game == nil)
    {
        // Could not find game in database. Try to import the file
        OEROMImporter *importer = [[OELibraryDatabase defaultDatabase] importer];
        OEImportItemCompletionBlock completion =
        ^(NSManagedObjectID *romID){
            
            // import probably failed
            if(!romID) return;
            
            NSManagedObjectContext *context = [[OELibraryDatabase defaultDatabase] mainThreadContext];
            OEDBRom *rom = [OEDBRom objectWithID:romID inContext:context];;
            [[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL:[rom URL] display:NO completionHandler:nil];
        };

        if([importer importItemAtURL:absoluteURL withCompletionHandler:completion])
        {
            if(outError != NULL)
                *outError = [NSError errorWithDomain:OEGameDocumentErrorDomain code:OEImportRequiredError userInfo:nil];
        }

        return NO;
    }

    // TODO: Load rom that was just imported instead of the default one
  
    //OEDBSaveState *state = [game autosaveForLastPlayedRom];
    //Wowfunhappy: Instead of retreiving the autosave from the database (as above), we  want to always try loading Auto Save State.oesavestate.
    OEDBSaveState *state = [OEDBSaveState createSaveStateByImportingBundleURL: [[[OELibraryDatabase defaultDatabase]  stateFolderURLForROM:[game defaultROM]] URLByAppendingPathComponent:@"Auto Save State.oesavestate/"] intoContext:[[OELibraryDatabase defaultDatabase] mainThreadContext]];
    
    if(state != nil /*&& [[OEHUDAlert loadAutoSaveGameAlert] runModal] == NSAlertDefaultReturn*/)
    {
        return [self OE_setupDocumentWithSaveState:state error:outError];
    }
    else {
        return [self OE_setupDocumentWithROM:[game defaultROM] usingCorePlugin:nil error:outError];
    }
}

#pragma mark - Menu Items

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];
    
    if(action == @selector(toggleEmulationPaused:))
    {
        if(_emulationStatus == OEEmulationStatusPaused)
        {
            [menuItem setTitle:OELocalizedString(@"Resume Emulation", @"")];
            return YES;
        }
        
        [menuItem setTitle:OELocalizedString(@"Pause Emulation", @"")];
        return _emulationStatus == OEEmulationStatusPlaying;
    }
    
    else if(action == @selector(setCheat:)) {
        if ([[[menuItem representedObject] objectForKey:@"enabled"] isEqualToValue:@YES]) {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    }
    
    return YES;
}

#pragma mark - Control Emulation

- (void)setupGameWithCompletionHandler:(void(^)(BOOL success, NSError *error))handler;
{
    if([self OE_checkRequiredFiles]) return;
    
    [self OE_checkGlitches];
    
    if(_emulationStatus != OEEmulationStatusNotSetup) return;

    [_gameCoreManager loadROMWithCompletionHandler:
     ^(id systemClient)
     {
         [_gameCoreManager setupEmulationWithCompletionHandler:
          ^(IOSurfaceID surfaceID, OEIntSize screenSize, OEIntSize aspectSize)
          {
              NSLog(@"SETUP DONE.");
              [_gameViewController setScreenSize:screenSize aspectSize:aspectSize withIOSurfaceID:surfaceID];

              _emulationStatus = OEEmulationStatusSetup;

              // TODO: #567 and #568 need to be fixed first
              //[self OE_addDeviceNotificationObservers];

              _gameSystemResponder = [_gameSystemController newGameSystemResponder];
              [_gameSystemResponder setClient:systemClient];
              [_gameSystemResponder setGlobalEventsHandler:self];

              [self disableOSSleep];
              //[[self rom] incrementPlayCount];
              //[[self rom] markAsPlayedNow];
              _lastPlayStartDate = [NSDate date];

              if(_saveStateForGameStart)
              {
                  [self OE_loadState:_saveStateForGameStart];
                  _saveStateForGameStart = nil;
              }

              // set initial volume
              [self setVolume:[self volume] asDefault:NO];

              handler(YES, nil);
          }];
     } errorHandler:
     ^(NSError *error)
     {
         _gameCoreManager = nil;
         [self close];

         handler(NO, error);
     }];
}

- (void)OE_startEmulation
{
    if(_emulationStatus != OEEmulationStatusSetup)
        return;

    _emulationStatus = OEEmulationStatusStarting;
    [_gameCoreManager startEmulationWithCompletionHandler:
     ^{
         _emulationStatus = OEEmulationStatusPlaying;
     }];
    
}

- (BOOL)isEmulationPaused
{
    return _emulationStatus != OEEmulationStatusPlaying;
}

- (void)setEmulationPaused:(BOOL)pauseEmulation
{
    if(_emulationStatus == OEEmulationStatusSetup)
    {
        if(!pauseEmulation) [self OE_startEmulation];
        return;
    }

    if(pauseEmulation)
    {
        [self enableOSSleep];
        _emulationStatus = OEEmulationStatusPaused;
        [[self rom] addTimeIntervalToPlayTime:ABS([_lastPlayStartDate timeIntervalSinceNow])];
        _lastPlayStartDate = nil;
    }
    else
    {
        [self disableOSSleep];
        [[self rom] markAsPlayedNow];
        _lastPlayStartDate = [NSDate date];
        _emulationStatus = OEEmulationStatusPlaying;
    }

    [_gameCoreManager setPauseEmulation:pauseEmulation];
}

// switchCore:: expects sender or [sender representedObject] to be an OECorePlugin object and prompts the user for confirmation
- (void)switchCore:(id)sender;
{
    OECorePlugin *plugin;
    if([sender isKindOfClass:[OECorePlugin class]])
        plugin = sender;
    else if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:[OECorePlugin class]])
        plugin = [sender representedObject];
    else
    {
        DLog(@"Invalid argument passed: %@", sender);
        return;
    }

    if([[plugin bundleIdentifier] isEqual:[[_gameCoreManager plugin] bundleIdentifier]]) return;

    OEHUDAlert *alert = [OEHUDAlert alertWithMessageText:OELocalizedString(@"If you change the core you current progress will be lost and save states will not work anymore.", @"")
                                           defaultButton:OELocalizedString(@"Change Core", @"")
                                         alternateButton:OELocalizedString(@"Cancel", @"")];
    [alert showSuppressionButtonForUDKey:OEAutoSwitchCoreAlertSuppressionKey];

    [alert setCallbackHandler:
     ^(OEHUDAlert *alert, NSUInteger result)
     {
         if(result != NSAlertDefaultReturn)
             return;

         NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
         [standardUserDefaults setValue:[self coreIdentifier] forKey:UDSystemCoreMappingKeyForSystemIdentifier([self systemIdentifier])];

         [self OE_setupGameCoreManagerUsingCorePlugin:plugin completionHandler:
          ^{
              [self OE_startEmulation];
          }];
     }];

    [alert runModal];
}

- (IBAction)editControls:(id)sender
{
    NSDictionary *userInfo = @{
        OEPreferencesUserInfoPanelNameKey : @"Controls",
        OEPreferencesUserInfoSystemIdentifierKey : [self systemIdentifier],
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:OEPreferencesOpenPaneNotificationName object:nil userInfo:userInfo];
}

- (void)toggleFullScreen:(id)sender
{
    [[[self gameWindowController] window] toggleFullScreen:sender];
}

- (void)takeScreenshot:(id)sender
{
    [[self gameViewController] takeScreenshot:sender];
}

#pragma mark - Volume

- (IBAction)changeAudioOutputDevice:(id)sender
{
    OEAudioDevice *device = nil;

    if([sender isKindOfClass:[OEAudioDevice class]])
        device = sender;
    else if ([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:[OEAudioDevice class]])
        device = [sender representedObject];

    if(device == nil)
    {
        DLog(@"Invalid argument: %@", sender);
        return;
    }

    [_gameCoreManager setAudioOutputDeviceID:[device deviceID]];
}

- (float)volume
{
    return [[NSUserDefaults standardUserDefaults] floatForKey:OEGameVolumeKey];
}

- (void)setVolume:(float)volume asDefault:(BOOL)defaultFlag
{
    [_gameCoreManager setVolume:volume];

    if(defaultFlag)
        [[NSUserDefaults standardUserDefaults] setValue:[NSNumber numberWithFloat:volume] forKey:OEGameVolumeKey];
}

- (IBAction)changeVolume:(id)sender;
{
    if([sender respondsToSelector:@selector(floatValue)])
        [self setVolume:[sender floatValue] asDefault:YES];
    else if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] respondsToSelector:@selector(floatValue)])
        [self setVolume:[[sender representedObject] floatValue] asDefault:YES];
    else
        DLog(@"Invalid argument passed: %@", sender);
}

- (void)toggleAudioMute:(id)sender;
{
    if(_isMuted)
        [self unmute:sender];
    else
        [self mute:sender];
}

- (IBAction)mute:(id)sender;
{
    _isMuted = YES;
    [self setVolume:0.0 asDefault:NO];
}

- (IBAction)unmute:(id)sender;
{
    _isMuted = NO;
    [self setVolume:[self volume] asDefault:NO];
}

- (void)volumeUp:(id)sender;
{
    CGFloat volume = [self volume];
    volume += 0.1;
    if(volume > 1.0) volume = 1.0;
    [self setVolume:volume asDefault:YES];
}

- (void)volumeDown:(id)sender;
{
    CGFloat volume = [self volume];
    volume -= 0.1;
    if(volume < 0.0) volume = 0.0;
    [self setVolume:volume asDefault:YES];
}

#pragma mark - Controlling Emulation
- (IBAction)performClose:(id)sender
{
    [self close];
}

- (IBAction)stopEmulation:(id)sender;
{
    [self close];
}

- (void)toggleEmulationPaused:(id)sender;
{
    [self setEmulationPaused:![self isEmulationPaused]];
}

- (void)resetEmulation:(id)sender;
{
    if([[OEHUDAlert resetSystemAlert] runModal] == NSAlertDefaultReturn)
    {
        [_gameCoreManager resetEmulationWithCompletionHandler:
         ^{
             [self setEmulationPaused:NO];
         }];
    }
}

- (BOOL)shouldTerminateEmulation
{
    [self enableOSSleep];
    [self setEmulationPaused:YES];

    //[[self controlsWindow] setCanShow:NO];

    /*if(![[OEHUDAlert stopEmulationAlert] runModal] == NSAlertDefaultReturn)
    {
        //[[self controlsWindow] setCanShow:YES];
        [self disableOSSleep];
        [self setEmulationPaused:NO];
        return NO;
    }*/

    return YES;
}

- (BOOL)isDocumentEdited
{
    return _emulationStatus == OEEmulationStatusPlaying || _emulationStatus == OEEmulationStatusPaused;
}

- (void)canCloseDocumentWithDelegate:(id)delegate shouldCloseSelector:(SEL)shouldCloseSelector contextInfo:(void *)contextInfo
{
    if(_emulationStatus == OEEmulationStatusNotSetup || _emulationStatus == OEEmulationStatusTerminating)
    {
        [super canCloseDocumentWithDelegate:delegate shouldCloseSelector:shouldCloseSelector contextInfo:contextInfo];
        return;
    }

    [self OE_pauseEmulationIfNeeded];

    if(![self shouldTerminateEmulation])
    {
        CAN_CLOSE_REPLY(delegate, shouldCloseSelector, self, NO, contextInfo);
        return;
    }

    [self OE_saveStateWithName:OESaveStateAutosaveName completionHandler:
     ^{
         _emulationStatus = OEEmulationStatusTerminating;
         // TODO: #567 and #568 need to be fixed first
         //[self OE_removeDeviceNotificationObservers];

         [_gameCoreManager stopEmulationWithCompletionHandler:
          ^{
              DLog(@"Emulation stopped");
              _emulationStatus = OEEmulationStatusNotSetup;

              _gameSystemController = nil;
              _gameSystemResponder  = nil;
              _gameCoreManager      = nil;

              //[[self rom] addTimeIntervalToPlayTime:ABS([_lastPlayStartDate timeIntervalSinceNow])];
              _lastPlayStartDate = nil;
          }];
         
         [super canCloseDocumentWithDelegate:delegate shouldCloseSelector:shouldCloseSelector contextInfo:contextInfo];
     }];
}

- (BOOL)OE_checkRequiredFiles
{
    // Check current system plugin for OERequiredFiles and core plugin for OEGameCoreRequiresFiles opt-in
    if ([[[_gameCoreManager plugin] controller] requiredFilesForSystemIdentifier:[_gameSystemController systemIdentifier]] != nil && [[[_gameCoreManager plugin] controller] requiresFilesForSystemIdentifier:[_gameSystemController systemIdentifier]]) {
        BOOL missingFileStatus = NO;
        NSSortDescriptor *sortedRequiredFiles = [NSSortDescriptor sortDescriptorWithKey:@"Name" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        NSArray *validRequiredFiles = [[[[_gameCoreManager plugin] controller] requiredFilesForSystemIdentifier:[_gameSystemController systemIdentifier]] sortedArrayUsingDescriptors:[NSArray arrayWithObject:sortedRequiredFiles]];
        NSMutableString *missingFilesMessage = [[NSMutableString alloc] init];
        NSMutableString *missingFilesList = [[NSMutableString alloc] init];
        
        for(NSDictionary *validRequiredFile in validRequiredFiles)
        {
            NSString *biosFilename = [validRequiredFile objectForKey:@"Name"];
            NSString *biosDescription = [validRequiredFile objectForKey:@"Description"];
            BOOL biosOptional = [[validRequiredFile objectForKey:@"Optional"] boolValue];
            NSString *biosPath = [NSString pathWithComponents:@[
                                                                [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject],
                                                                @"OpenEmu", @"BIOS"]];
            NSString *destFilePath = [biosPath stringByAppendingPathComponent:biosFilename];
            
            // Check if the required files exist and are optional
            if (![[NSFileManager defaultManager] fileExistsAtPath:destFilePath] && !biosOptional)
            {
                missingFileStatus = YES;
                [missingFilesList appendString:[NSString stringWithFormat:@"%@\n\t\"%@\"\n\n", biosDescription, biosFilename]];
            }
            
        }
        // Alert the user of missing BIOS/system files that are required for the core
        if (missingFileStatus)
        {
            [missingFilesMessage appendString:[NSString stringWithFormat:OELocalizedString(@"To run this core you need the following:\n\n%@Drag and drop the required file(s) onto the game library window and try again.", @"Missing files dialog text"), missingFilesList]];
            
            OEHUDAlert *alert = [OEHUDAlert alertWithMessageText:OELocalizedString(missingFilesMessage, @"")
                                                   defaultButton:OELocalizedString(@"OK", @"")
                                                 alternateButton:nil];
            [alert setHeadlineText:OELocalizedString(@"Required files are missing.", @"")];
            [alert runModal];
            
            return YES;
        }
    }
    return NO;
}

- (BOOL)OE_checkGlitches
{
    NSString *OEGameCoreGlitchesKey       = OEGameCoreGlitchesSuppressionKey;
    NSString *OEGameCoreGlitchesKeyFormat = @"%@.%@";
    NSString *coreName                    = [[[_gameCoreManager plugin] controller] pluginName];
    NSString *systemIdentifier            = [_gameSystemController systemIdentifier];
    NSString *systemKey                   = [NSString stringWithFormat:OEGameCoreGlitchesKeyFormat, coreName, systemIdentifier];
    NSUserDefaults *userDefaults          = [NSUserDefaults standardUserDefaults];
    
    NSDictionary *glitchInfo              = [userDefaults objectForKey:OEGameCoreGlitchesKey];
    BOOL showAlert                        = ![[glitchInfo valueForKey:systemKey] boolValue];
    
    if([[[_gameCoreManager plugin] controller] hasGlitchesForSystemIdentifier:[_gameSystemController systemIdentifier]] && showAlert)
    {
        NSString *message = [NSString stringWithFormat:OELocalizedString(@"The %@ core has compatibility issues and some games may contain glitches or not play at all.\n\nPlease do not report problems as we are not responsible for the development of %@.", @""), coreName, coreName];
        OEHUDAlert *alert = [OEHUDAlert alertWithMessageText:message
                                               defaultButton:OELocalizedString(@"OK", @"")
                                             alternateButton:nil];
        [alert setHeadlineText:OELocalizedString(@"Warning", @"")];
        [alert setShowsSuppressionButton:YES];
        [alert setSuppressionLabelText:OELocalizedString(@"Do not show me again", @"Alert suppression label")];
        
        if([alert runModal] && [[alert suppressionButton] state] == NSOnState)
        {
            NSMutableDictionary *systemKeyGlitchInfo = [NSMutableDictionary dictionary];
            [systemKeyGlitchInfo addEntriesFromDictionary:glitchInfo];
            [systemKeyGlitchInfo setValue:@YES forKey:systemKey];
            
            [userDefaults setObject:systemKeyGlitchInfo forKey:OEGameCoreGlitchesKey];
            [userDefaults synchronize];
        }
        
        return YES;
    }
    return NO;
}

#pragma mark - Cheats

- (BOOL)supportsCheats
{
    return [[[_gameCoreManager plugin] controller] supportsCheatCodeForSystemIdentifier:[_gameSystemController systemIdentifier]];
}

- (IBAction)addCheat:(id)sender;
{
    OEHUDAlert *alert = [[OEHUDAlert alloc] init];

    [alert setOtherInputLabelText:OELocalizedString(@"Title:", @"")];
    [alert setShowsOtherInputField:YES];
    [alert setOtherStringValue:OELocalizedString(@"Cheat Description", @"")];

    [alert setInputLabelText:OELocalizedString(@"Code:", @"")];
    [alert setShowsInputField:YES];
    [alert setStringValue:@"Join multi-line cheats with '+' e.g. 000-000+111-111"];

    [alert setDefaultButtonTitle:OELocalizedString(@"Add Cheat", @"")];
    [alert setAlternateButtonTitle:OELocalizedString(@"Cancel", @"")];
    
    [alert setShowsSuppressionButton:YES];
    [alert setSuppressionLabelText:OELocalizedString(@"Enable now", @"Cheats button label")];

    [alert setInputLimit:1000];

    if([alert runModal])
    {
        NSNumber *enabled;
        if ([[alert suppressionButton] state] == NSOnState)
        {
            enabled = @YES;
            [self setCheat:[alert stringValue] withType:@"Unknown" enabled:[enabled boolValue]];
        }
        else
        {
            enabled = @NO;
        }
        
        TODO("decide how to handle setting a cheat type from the modal and save added cheats to file");
        [[sender representedObject] addObject:[@{
             @"code" : [alert stringValue],
             @"type" : @"Unknown",
             @"description" : [alert otherStringValue],
             @"enabled" : enabled,
         } mutableCopy]];
    }
}

- (IBAction)setCheat:(id)sender;
{
    NSString *code, *type;
    BOOL enabled;
    code = [[sender representedObject] objectForKey:@"code"];
    type = [[sender representedObject] objectForKey:@"type"];
    enabled = [[[sender representedObject] objectForKey:@"enabled"] boolValue];

    if (enabled) {
        [[sender representedObject] setObject:@NO forKey:@"enabled"];
        enabled = NO;
    }
    else {
        [[sender representedObject] setObject:@YES forKey:@"enabled"];
        enabled = YES;
    }

    [self setCheat:code withType:type enabled:enabled];
}

- (IBAction)toggleCheat:(id)sender;
{
    NSString *code = [[sender representedObject] objectForKey:@"code"];
    NSString *type = [[sender representedObject] objectForKey:@"type"];
    BOOL enabled = ![[[sender representedObject] objectForKey:@"enabled"] boolValue];
    [[sender representedObject] setObject:@(enabled) forKey:@"enabled"];
    [self setCheat:code withType:type enabled:enabled];
}

- (void)setCheat:(NSString *)cheatCode withType:(NSString *)type enabled:(BOOL)enabled;
{
    [_gameCoreManager setCheat:cheatCode withType:type enabled:enabled];
}

#pragma mark - Saving States

- (BOOL)supportsSaveStates
{
    return ![[[_gameCoreManager plugin] controller] saveStatesNotSupportedForSystemIdentifier:[_gameSystemController systemIdentifier]];
}

- (BOOL)OE_pauseEmulationIfNeeded
{
    BOOL pauseNeeded = _emulationStatus == OEEmulationStatusPlaying;

    if(pauseNeeded) [self setEmulationPaused:YES];

    return pauseNeeded;
}

- (void)saveState:(id)sender;
{
    if(![self supportsSaveStates])
        return;
    
    BOOL didPauseEmulation = [self OE_pauseEmulationIfNeeded];

    NSInteger   saveGameNo    = [[self rom] saveStateCount] + 1;
    // TODO: properly format date
    NSDate *date = [NSDate date];
    NSString *format = OELocalizedString(@"Save-Game-%ld %@", @"default save game name");
    NSString    *proposedName = [NSString stringWithFormat:format, saveGameNo, date];
    OEHUDAlert  *alert        = [OEHUDAlert saveGameAlertWithProposedName:proposedName];

    [alert setWindow:[[[self gameViewController] view] window]];
    [alert setCallbackHandler:
     ^(OEHUDAlert *alert, NSUInteger result)
     {
         if(result == NSAlertDefaultReturn)
         {
             [self OE_saveStateWithName:[alert stringValue] completionHandler:
              ^{
                  if(didPauseEmulation) [self setEmulationPaused:NO];
              }];
         }
         else if(didPauseEmulation) [self setEmulationPaused:NO];
     }];

    [alert runModal];
}

- (void)quickSave:(id)sender;
{
    NSInteger slot = 0;
    if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] respondsToSelector:@selector(intValue)])
        slot = [[sender representedObject] integerValue];
    else if([sender respondsToSelector:@selector(tag)])
        slot = [sender tag];

    NSString *name = [OEDBSaveState nameOfQuickSaveInSlot:slot];
    BOOL didPauseEmulation = [self OE_pauseEmulationIfNeeded];

    [self OE_saveStateWithName:name completionHandler:
     ^{
         if(didPauseEmulation) [self setEmulationPaused:NO];
         [[[self gameViewController] gameView] showQuickSaveNotification];
    }];
}

- (void)OE_saveStateWithName:(NSString *)stateName completionHandler:(void(^)(void))handler
{
    NSAssert(_emulationStatus > OEEmulationStatusStarting, @"Cannot save state if emulation has not been set up");
    NSAssert([self rom] != nil, @"Cannot save states without a rom.");

    NSString *temporaryDirectoryPath = NSTemporaryDirectory();
    NSURL    *temporaryDirectoryURL  = [NSURL fileURLWithPath:temporaryDirectoryPath];
    NSURL    *temporaryStateFileURL  = [NSURL URLWithString:[NSString stringWithUUID] relativeToURL:temporaryDirectoryURL];
    OECorePlugin *core = [_gameCoreManager plugin];

    temporaryStateFileURL =
    [temporaryStateFileURL uniqueURLUsingBlock:
     ^ NSURL *(NSInteger triesCount)
     {
         return [NSURL URLWithString:[NSString stringWithUUID] relativeToURL:temporaryDirectoryURL];
     }];

    [_gameCoreManager saveStateToFileAtPath:[temporaryStateFileURL path] completionHandler:
     ^(BOOL success, NSError *error)
     {
         if(!success)
         {
             NSLog(@"Could not create save state file at url: %@", temporaryStateFileURL);

             if(handler != nil) handler();
             return;
         }

         OEDBSaveState *state;
         if([stateName hasPrefix:OESaveStateSpecialNamePrefix])
         {
             state = [[self rom] saveStateWithName:stateName];

             NSString *coreIdentifier = [core bundleIdentifier];
             NSString *coreVersion = [core version];
             [state setCoreIdentifier:coreIdentifier];
             [state setCoreVersion:coreVersion];
         }

         if(state == nil)
         {
             NSManagedObjectContext *context = [[OELibraryDatabase defaultDatabase] mainThreadContext];
             state = [OEDBSaveState createSaveStateNamed:stateName forRom:[self rom] core:core withFile:temporaryStateFileURL inContext:context];
         }
         else
         {
             [state replaceStateFileWithFile:temporaryStateFileURL];
             [state setTimestamp:[NSDate date]];
         }

         [state save];
         NSManagedObjectContext *mainContext = [state managedObjectContext];
         [mainContext performBlock:^{
             [mainContext save:nil];
         }];

         NSData *TIFFData = [[[self gameViewController] takeNativeScreenshot] TIFFRepresentation];
         NSBitmapImageRep *bitmapImageRep = [NSBitmapImageRep imageRepWithData:TIFFData];

         NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
         NSBitmapImageFileType type = [standardUserDefaults integerForKey:OEScreenshotFileFormatKey];
         NSDictionary *properties = [standardUserDefaults dictionaryForKey:OEScreenshotPropertiesKey];
         NSData *convertedData = [bitmapImageRep representationUsingType:type properties:properties];

         __autoreleasing NSError *saveError = nil;
         if([state screenshotURL] == nil || ![convertedData writeToURL:[state screenshotURL] options:NSDataWritingAtomic error:&saveError])
             NSLog(@"Could not create screenshot at url: %@ with error: %@", [state screenshotURL], saveError);

         if(handler != nil) handler();
     }];
}

#pragma mark - Loading States

- (void)loadState:(id)sender;
{
    // calling pauseGame here because it might need some time to execute
    [self OE_pauseEmulationIfNeeded];

    OEDBSaveState *state = nil;
    if([sender isKindOfClass:[OEDBSaveState class]])
        state = sender;
    else if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:[OEDBSaveState class]])
        state = [sender representedObject];
    else
    {
        DLog(@"Invalid argument passed: %@", sender);
        return;
    }

    [self OE_loadState:state];
}

- (void)quickLoad:(id)sender;
{
    NSInteger slot = 0;
    if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] respondsToSelector:@selector(intValue)])
        slot = [[sender representedObject] integerValue];
    else if([sender respondsToSelector:@selector(tag)])
        slot = [sender tag];

    OEDBSaveState *quicksaveState = [[self rom] quickSaveStateInSlot:slot];
    if(quicksaveState!= nil) [self loadState:quicksaveState];
}

- (void)OE_loadState:(OEDBSaveState *)state
{
    if([state rom] != [self rom])
    {
        DLog(@"Invalid save state for current rom");
        return;
    }

    void (^loadState)(void) =
    ^{
        [_gameCoreManager loadStateFromFileAtPath:[[state dataFileURL] path] completionHandler:
         ^(BOOL success, NSError *error)
         {
             if(!success)
             {
                 [self presentError:error];
                 return;
             }

             [self setEmulationPaused:NO];
         }];
    };

    if([[[_gameCoreManager plugin] bundleIdentifier] isEqualToString:[state coreIdentifier]])
    {
        loadState();
        return;
    }

    [self OE_startEmulation];
}


#pragma mark - Deleting States

// delete save state expects sender or [sender representedObject] to be an OEDBSaveState object and prompts the user for confirmation
- (IBAction)deleteSaveState:(id)sender;
{
    OEDBSaveState *state;
    if([sender isKindOfClass:[OEDBSaveState class]])
        state = sender;
    else if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:[OEDBSaveState class]])
        state = [sender representedObject];
    else
    {
        DLog(@"Invalid argument passed: %@", sender);
        return;
    }

    NSString *stateName = [state name];
    OEHUDAlert *alert = [OEHUDAlert deleteStateAlertWithStateName:stateName];

    if([alert runModal]) [state deleteAndRemoveFiles];
}

#pragma mark - OEGameViewControllerDelegate methods

- (void)gameViewController:(OEGameViewController *)sender didReceiveMouseEvent:(OEEvent *)event;
{
    [[self gameSystemResponder] handleMouseEvent:event];
}

- (void)gameViewController:(OEGameViewController *)sender setDrawSquarePixels:(BOOL)drawSquarePixels
{
    [_gameCoreManager setDrawSquarePixels:drawSquarePixels];
}

#pragma mark OEGameCoreDisplayHelper methods

- (void)setEnableVSync:(BOOL)enable;
{
    [[self gameViewController] setEnableVSync:enable];
}

- (void)setScreenSize:(OEIntSize)newScreenSize withIOSurfaceID:(IOSurfaceID)newSurfaceID;
{
    [[self gameViewController] setScreenSize:newScreenSize withIOSurfaceID:newSurfaceID];
}

- (void)setAspectSize:(OEIntSize)newAspectSize;
{
    [[self gameViewController] setAspectSize:newAspectSize];
}

@end
