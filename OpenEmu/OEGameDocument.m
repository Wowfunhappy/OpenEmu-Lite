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
#import "OECheats.h"
#import "OECheatsWindowController.h"
#import "OECorePlugin.h"
#import "OERom.h"
#import "OESaveState.h"
#import "OEDOGameCoreManager.h"
#import "OEGameCoreManager.h"
#import "OEGameView.h"
#import "OEGameViewController.h"
#import "OEHUDWindow.h"
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

// Suppression-button UserDefaults key for the Reset Console confirmation. It
// used to live in OEHUDAlert+DefaultAlertsAdditions; it's kept here (with its
// original string value) now that the alert is a plain NSAlert, so a user who
// already ticked "Do not ask me again" stays suppressed.
NSString *const OEResetSystemAlertSuppressionKey  = @"resetSystemWithoutConfirmation";

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
    OESaveState        *_saveStateForGameStart;
    NSDate             *_lastPlayStartDate;
    BOOL                _isMuted;
    BOOL                _isFastForwarding;
    //BOOL                _pausedByGoingToBackground;
    BOOL                _isTerminatingEmulation;

    NSMutableArray     *_cheats;
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

- (id)initWithRom:(OERom *)rom core:(OECorePlugin *)core error:(NSError **)outError
{
    if(!(self = [self init]))
        return nil;

    if(![self OE_setupDocumentWithROM:rom usingCorePlugin:core error:outError])
        return nil;

    return self;
}

- (id)initWithSaveState:(OESaveState *)state error:(NSError **)outError
{
    if(!(self = [self init]))
        return nil;

    if(![self OE_setupDocumentWithSaveState:state error:outError])
        return nil;

    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@ %p, ROM: '%@', System: '%@', Core: '%@'>", [self class], self, [[self rom] name], [_systemPlugin systemIdentifier], [_corePlugin bundleIdentifier]];
}

- (NSString *)coreIdentifier;
{
    return [[_gameCoreManager plugin] bundleIdentifier];
}

- (NSString *)systemIdentifier;
{
    return [_gameSystemController systemIdentifier];
}

- (BOOL)OE_setupDocumentWithSaveState:(OESaveState *)saveState error:(NSError **)outError
{
    // We don't have the ROM object yet — the caller should set up the ROM first
    // and pass the save state separately via _saveStateForGameStart
    _saveStateForGameStart = saveState;
    return YES;
}

- (BOOL)OE_setupDocumentWithROM:(OERom *)rom usingCorePlugin:(OECorePlugin *)core error:(NSError **)outError
{
    NSURL *fileURL = [rom url];

    _rom = rom;
    _romFileURL = fileURL;
    _corePlugin = core;
    _systemPlugin = [rom systemPlugin];
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
    if([url isNotEqualTo:[[self rom] url]])
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
    NSString *displayName = [[self rom] name];
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

    if([typeName isEqualToString:@"org.openemu.savestate"])
    {
        OESaveState *state = [OESaveState saveStateWithBundleURL:absoluteURL];
        if(state)
        {
            [self OE_setupDocumentWithSaveState:state error:outError];
            // We still need a ROM to set up the document
            // For now, save states opened directly aren't supported without the ROM
            return NO;
        }
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

    if(![absoluteURL isFileURL])
    {
        DLog(@"URLs that are not file urls are currently not supported!");
        return NO;
    }

    OERom *rom = [OERom romWithURL:absoluteURL];

    // Try to restore autosave so the user picks up where they left off
    OESaveState *autosave = [rom autosaveState];
    if(autosave != nil)
    {
        if(![self OE_setupDocumentWithROM:rom usingCorePlugin:[OECorePlugin corePluginWithBundleIdentifier:[autosave coreIdentifier]] error:outError])
            return NO;
        _saveStateForGameStart = autosave;
        return YES;
    }

    return [self OE_setupDocumentWithROM:rom usingCorePlugin:nil error:outError];
}

#pragma mark - Menu Items

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
    SEL action = [menuItem action];
    
    if(action == @selector(toggleEmulationPaused:))
    {
        if(_emulationStatus == OEEmulationStatusPaused)
        {
            [menuItem setState:NSOnState];
            return YES;
        }

        [menuItem setState:NSOffState];
        return _emulationStatus == OEEmulationStatusPlaying;
    }

    if(action == @selector(toggleFastForward:))
    {
        [menuItem setState:_isFastForwarding ? NSOnState : NSOffState];
        return _emulationStatus == OEEmulationStatusPlaying || _emulationStatus == OEEmulationStatusPaused;
    }

    if(action == @selector(toggleAudioMute:))
    {
        if(_isMuted)
        {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    }
    
    else if(action == @selector(setCheat:)) {
        if ([[[menuItem representedObject] objectForKey:@"enabled"] isEqualToValue:@YES]) {
            [menuItem setState:NSOnState];
        } else {
            [menuItem setState:NSOffState];
        }
    }

    else if(action == @selector(manageCheats:)) {
        return [self supportsCheats];
    }

    else if(action == @selector(OE_selectCheatsParentMenuItem:)) {
        return [self supportsCheats];
    }

    return YES;
}

#pragma mark - Control Emulation

- (void)setupGameWithCompletionHandler:(void(^)(BOOL success, NSError *error))handler;
{
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
         [self OE_applyEnabledCheats];
     }];

}

// Apply any cheat the user left enabled once the freshly-loaded game is running,
// so persisted "on" cheats take effect automatically. Applying after the core has
// started (rather than into a cold boot) means a game that verifies its ROM
// checksum at power-on (e.g. Sonic 2) still boots, then gets patched.
- (void)OE_applyEnabledCheats
{
    if(![self supportsCheats]) return;

    for(NSDictionary *cheat in [self cheats])
    {
        if([[cheat objectForKey:@"enabled"] boolValue])
            [self setCheat:[cheat objectForKey:@"code"] withType:[cheat objectForKey:@"type"] enabled:YES];
    }
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

    if(pauseEmulation && _isFastForwarding)
    {
        // Pausing automatically exits double speed.
        _isFastForwarding = NO;
        [_gameCoreManager fastForward:NO];
    }

    if(pauseEmulation)
    {
        [self enableOSSleep];
        _emulationStatus = OEEmulationStatusPaused;
        _lastPlayStartDate = nil;
    }
    else
    {
        [self disableOSSleep];
        _lastPlayStartDate = [NSDate date];
        _emulationStatus = OEEmulationStatusPlaying;
    }

    [_gameCoreManager setPauseEmulation:pauseEmulation];
    [self OE_updateGameViewColorTint];
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

- (IBAction)toggleAudioMute:(id)sender;
{
    if(_isMuted)
        [self unmute:sender];
    else
        [self mute:sender];
}

- (IBAction)toggleSquarePixels:(id)sender;
{
    [_gameCoreManager setDrawSquarePixels:true];
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

- (IBAction)toggleFastForward:(id)sender;
{
    _isFastForwarding = !_isFastForwarding;
    [_gameCoreManager fastForward:_isFastForwarding];

    // Enabling double speed automatically exits pause.
    if(_isFastForwarding && _emulationStatus == OEEmulationStatusPaused)
        [self setEmulationPaused:NO];

    [self OE_updateGameViewColorTint];
}

- (void)OE_updateGameViewColorTint
{
    OEGameView *gameView = [[self gameViewController] gameView];
    [gameView setFastForwarding:_isFastForwarding];
    [gameView setShowsPausedTint:(_emulationStatus == OEEmulationStatusPaused)];
}

- (void)resetEmulation:(id)sender;
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // Honor a previously-set "Do not ask me again": reset without confirming.
    if(![defaults boolForKey:OEResetSystemAlertSuppressionKey])
    {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:OELocalizedString(@"Are you sure you want to reset the console?", @"")];
        [alert addButtonWithTitle:OELocalizedString(@"Restart", @"")];
        [alert addButtonWithTitle:OELocalizedString(@"Cancel", @"")];
        [alert setShowsSuppressionButton:YES];

        if([alert runModal] != NSAlertFirstButtonReturn)
            return;

        // Only remember the choice when the user actually confirmed the reset.
        if([[alert suppressionButton] state] == NSOnState)
            [defaults setBool:YES forKey:OEResetSystemAlertSuppressionKey];
    }

    // Enabled cheats stay applied across a reset: a Game Genie ROM patch
    // persists in the loaded ROM through system_reset, mirroring how a real
    // Game Genie stays plugged in. (A game that verifies its ROM checksum at
    // boot, e.g. Sonic 2, will therefore need a companion checksum-disable
    // code to survive a reset with a code active — same as on hardware.)
    [_gameCoreManager resetEmulationWithCompletionHandler:
     ^{
         // Force status to playing without going through setPauseEmulation:,
         // which would send a pause button press to the freshly reset core.
         [self disableOSSleep];
         _lastPlayStartDate = [NSDate date];
         _emulationStatus = OEEmulationStatusPlaying;
         [self OE_updateGameViewColorTint];
     }];
}

- (BOOL)shouldTerminateEmulation
{
    [self enableOSSleep];
    [self setEmulationPaused:YES];

    // We pause here only to freeze the core while we autosave and tear down —
    // the user didn't pause, and the window is about to close. Suppress the
    // yellow "paused" tint so it doesn't briefly flash on quit.
    [[[self gameViewController] gameView] setShowsPausedTint:NO];

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
         // Bump the ROM file's modification date so QuickLook regenerates its thumbnail
         // from the freshly-written save-state screenshot.
         NSURL *romURL = [self romFileURL];
         if(romURL)
             [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate date]}
                                              ofItemAtPath:[romURL path]
                                                     error:NULL];

         _emulationStatus = OEEmulationStatusTerminating;

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

#pragma mark - Cheats

- (BOOL)supportsCheats
{
    return [[[_gameCoreManager plugin] controller] supportsCheatCodeForSystemIdentifier:[_gameSystemController systemIdentifier]];
}

- (NSMutableArray *)cheats
{
    // Loaded lazily from the persistent store keyed by the ROM md5.
    if(_cheats == nil)
        _cheats = [OECheats cheatsForMD5:[[self rom] md5Hash]];
    return _cheats;
}

- (void)saveCheats
{
    [OECheats setCheats:[self cheats] forMD5:[[self rom] md5Hash]];
}

- (void)addNewCheat
{
    // Newly added cheats start disabled; enabling is an explicit user action.
    [[self cheats] addObject:[@{
        @"description" : OELocalizedString(@"Untitled Cheat", @""),
        @"code"        : @"",
        @"type"        : @"Unknown",
        @"enabled"     : @NO,
    } mutableCopy]];
    [self saveCheats];
}

- (void)removeCheatAtIndex:(NSUInteger)index
{
    if(index >= [[self cheats] count]) return;

    NSMutableDictionary *cheat = [[self cheats] objectAtIndex:index];

    // Turn the cheat off in the running core before forgetting about it.
    if([[cheat objectForKey:@"enabled"] boolValue])
        [self setCheat:[cheat objectForKey:@"code"] withType:[cheat objectForKey:@"type"] enabled:NO];

    [[self cheats] removeObjectAtIndex:index];
    [self saveCheats];
}

- (IBAction)manageCheats:(id)sender;
{
    [[OECheatsWindowController sharedController] showCheatsForDocument:self];
}

// No-op: exists only so the front document can enable/disable the
// Emulation ▸ Cheats parent menu item through validateMenuItem:. Clicking the
// item just opens its submenu.
- (IBAction)OE_selectCheatsParentMenuItem:(id)sender;
{
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
    [self saveCheats];
}

- (IBAction)toggleCheat:(id)sender;
{
    NSString *code = [[sender representedObject] objectForKey:@"code"];
    NSString *type = [[sender representedObject] objectForKey:@"type"];
    BOOL enabled = ![[[sender representedObject] objectForKey:@"enabled"] boolValue];
    [[sender representedObject] setObject:@(enabled) forKey:@"enabled"];
    [self setCheat:code withType:type enabled:enabled];
    [self saveCheats];
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

// Required by the OEGlobalEventsHandler protocol. OpenEmu Lite exposes no UI for
// manually naming save states (only the automatic save-on-close is used), so
// this saves directly with a generated name instead of prompting.
- (void)saveState:(id)sender;
{
    if(![self supportsSaveStates])
        return;

    NSString *format = OELocalizedString(@"Save-Game-%ld %@", @"default save game name");
    NSString *proposedName = [NSString stringWithFormat:format, (long)1, [NSDate date]];
    [self OE_saveStateWithName:proposedName completionHandler:nil];
}

- (void)quickSave:(id)sender;
{
    NSInteger slot = 0;
    if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] respondsToSelector:@selector(intValue)])
        slot = [[sender representedObject] integerValue];
    else if([sender respondsToSelector:@selector(tag)])
        slot = [sender tag];

    NSString *name = [OESaveState nameOfQuickSaveInSlot:slot];

    [self OE_saveStateWithName:name completionHandler:
     ^{
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

         OESaveState *state;
         if([stateName hasPrefix:OESaveStateSpecialNamePrefix])
         {
             state = [[self rom] saveStateWithName:stateName];

             [state setCoreIdentifier:[core bundleIdentifier]];
             [state setCoreVersion:[core version]];
         }

         if(state == nil)
         {
             state = [OESaveState createSaveStateNamed:stateName forRom:[self rom] core:core withFile:temporaryStateFileURL];
         }
         else
         {
             [state replaceStateFileWithFile:temporaryStateFileURL];
             [state setTimestamp:[NSDate date]];
         }

         [state writeToDisk];

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
    OESaveState *state = nil;
    if([sender isKindOfClass:[OESaveState class]])
        state = sender;
    else if([sender respondsToSelector:@selector(representedObject)] && [[sender representedObject] isKindOfClass:[OESaveState class]])
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

- (void)OE_loadState:(OESaveState *)state
{
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

             // Release all possible buttons to clear any input state
             // captured in the save state. Without this, buttons held
             // when the state was saved would appear stuck on restore.
             for(NSUInteger key = 0; key < 32; key++)
             {
                 for(NSUInteger player = 1; player <= 8; player++)
                 {
                     OESystemKey *sysKey = [OESystemKey systemKeyWithKey:key player:player isAnalogic:NO];
                     [_gameSystemResponder releaseEmulatorKey:sysKey];
                 }
             }
         }];
    };

    NSString *currentCore = [[_gameCoreManager plugin] bundleIdentifier];
    NSString *stateCore = [state coreIdentifier];
    if([currentCore isEqualToString:stateCore])
    {
        loadState();
        return;
    }

    [self OE_startEmulation];
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
