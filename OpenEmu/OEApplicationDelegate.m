/*
 Copyright (c) 2011, OpenEmu Team

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

#import "OEApplicationDelegate.h"

#import "OEPlugin.h"
#import "OECorePlugin.h"

#import "OESystemPlugin.h"
#import "OECompositionPlugin.h"
#import "OEShaderPlugin.h"

#import "NSAttributedString+Hyperlink.h"
#import "NSImage+OEDrawingAdditions.h"
#import "NSWindow+OEFullScreenAdditions.h"

#import "OEHUDAlert+DefaultAlertsAdditions.h"
#import "OEGameDocument.h"

#import "OERom.h"

#import "OEBuildVersion.h"

#import "OEPreferencesController.h"
#import "OEGameViewController.h"

#import <OpenEmuSystem/OpenEmuSystem.h>
#import "OEToolTipManager.h"

#import "OEXPCGameCoreManager.h"

#import <OpenEmuXPCCommunicator/OpenEmuXPCCommunicator.h>
#import <objc/message.h>

#import "OESaveState.h"

NSString *const OEWebSiteURL      = @"http://openemu.org/";
NSString *const OEUserGuideURL    = @"https://github.com/OpenEmu/OpenEmu/wiki/User-guide";
NSString *const OEReleaseNotesURL = @"https://github.com/OpenEmu/OpenEmu/wiki/Release-notes";
NSString *const OEFeedbackURL     = @"https://github.com/OpenEmu/OpenEmu/issues";

static void *const _OEApplicationDelegateAllPluginsContext = (void *)&_OEApplicationDelegateAllPluginsContext;

@interface OEApplicationDelegate ()
{
    NSMutableArray *_gameDocuments;

    id _HIDEventsMonitor;
    id _keyboardEventsMonitor;
    id _unhandledEventsMonitor;
}

@property(strong) NSArray *cachedLastPlayedInfo;

@property(nonatomic) BOOL logHIDEvents;
@property(nonatomic) BOOL logKeyboardEvents;

@property(nonatomic) BOOL libraryLoaded;
@property(nonatomic) NSMutableArray *startupQueue;
@end

@implementation OEApplicationDelegate
@synthesize mainWindowController, preferencesController;
@synthesize aboutWindow, aboutCreditsPath, cachedLastPlayedInfo;

+ (void)load
{
    Class NSXPCConnectionClass = NSClassFromString(@"NSXPCConnection");
    if(NSXPCConnectionClass != nil)
    {
        NSString *OEXPCCFrameworkPath = [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"OpenEmuXPCCommunicator.framework"];
        NSBundle *frameworkBundle = [NSBundle bundleWithPath:OEXPCCFrameworkPath];
        [frameworkBundle load];
    }
}

+ (void)initialize
{
    if(self == [OEApplicationDelegate class])
    {
        [[NSUserDefaults standardUserDefaults] registerDefaults:
         @{
                                       OEWiimoteSupportEnabled : @YES,
                                   OEGameDefaultVideoFilterKey : @"GTU",
                                               OEGameVolumeKey : @0.5f,
                              @"defaultCore.openemu.system.gb" : @"org.openemu.Gambatte",
                             @"defaultCore.openemu.system.gba" : @"org.openemu.VisualBoyAdvance",
                             @"defaultCore.openemu.system.nes" : @"org.openemu.Nestopia",
                            @"defaultCore.openemu.system.snes" : @"org.openemu.SNES9x",
                                          OEBackgroundPauseKey : @YES,
                                              @"logsHIDEvents" : @NO,
                                    @"logsHIDEventsNoKeyboard" : @NO,
         }];

        [OEControllerDescription class];
        [OEToolTipManager class];
    }
}


- (instancetype)init
{
    self = [super init];
    if (self) {
        [self setStartupQueue:[NSMutableArray array]];
    }
    return self;
}

- (void)dealloc
{
    [[OECorePlugin class] removeObserver:self forKeyPath:@"allPlugins" context:_OEApplicationDelegateAllPluginsContext];
}

#pragma mark -
- (void)OE_ensureInitialized
{
    if(_libraryLoaded) return;
    _libraryLoaded = YES;

    [self OE_loadPlugins];
    _gameDocuments = [NSMutableArray array];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    [self OE_ensureInitialized];

    DLog();
    //mainWindowController  = [[OEMainWindowController alloc]  initWithWindowNibName:@"MainWindow"];
    //[mainWindowController loadWindow];
    preferencesController = [[OEPreferencesController alloc] initWithWindowNibName:@"Preferences"];
    [preferencesController loadWindow];

    // Remove the Open Recent menu item
    /*NSMenu *fileMenu = [self fileMenu];
    NSInteger openDocumentMenuItemIndex = [fileMenu indexOfItemWithTarget:nil andAction:@selector(openDocument:)];

    if(openDocumentMenuItemIndex >= 0 && [[fileMenu itemAtIndex:openDocumentMenuItemIndex + 1] hasSubmenu])
        [fileMenu removeItemAtIndex:openDocumentMenuItemIndex + 1];*/

    // update extensions
    [self updateInfoPlist];

    // Setup HID Support
    [self OE_setupHIDSupport];

    // Replace quick save / quick load items with menus if required
    //[self OE_updateControlsMenu];

    NSUserDefaultsController *sudc = [NSUserDefaultsController sharedUserDefaultsController];
    [self bind:@"logHIDEvents" toObject:sudc withKeyPath:@"values.logsHIDEvents" options:nil];
    [self bind:@"logKeyboardEvents" toObject:sudc withKeyPath:@"values.logsHIDEventsNoKeyboard" options:nil];

    _unhandledEventsMonitor =
    [[OEDeviceManager sharedDeviceManager] addUnhandledEventMonitorHandler:
     ^(OEDeviceHandler *handler, OEHIDEvent *event)
     {
         if(![NSApp isActive] && [event type] == OEHIDEventTypeKeyboard) return;

         [[[self currentGameDocument] gameSystemResponder] handleHIDEvent:event];
     }];

    // Start retrode support
    /*if([[NSUserDefaults standardUserDefaults] boolForKey:OERetrodeSupportEnabledKey])
        [OERetrodeDeviceManager class];*/


    [[self startupQueue] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        void(^block)(void) = obj;
        block();
    }];
    [self setStartupQueue:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    if([OEXPCGameCoreManager canUseXPCGameCoreManager])
        [[OEXPCCAgentConfiguration defaultConfiguration] tearDownAgent];
}

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication *)sender
{
    return NO;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray *)filenames
{
    [self OE_ensureInitialized];

    for (NSString *fileString in filenames) {
        NSURL *url = [NSURL fileURLWithPath:fileString];
        [self openDocumentWithContentsOfURL:url display:YES completionHandler:
         ^(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error)
         {
             NSApplicationDelegateReply reply = (document != nil) ? NSApplicationDelegateReplySuccess : NSApplicationDelegateReplyFailure;
             [NSApp replyToOpenOrPrint:reply];
         }];
    }
}

#pragma mark - NSDocumentController Overrides

- (void)addDocument:(NSDocument *)document
{
    if([document isKindOfClass:[OEGameDocument class]]) {
        [_gameDocuments addObject:document];
    }
    [super addDocument:document];
}

- (void)removeDocument:(NSDocument *)document
{
    if([document isKindOfClass:[OEGameDocument class]])
        [_gameDocuments removeObject:document];

    [super removeDocument:document];
}

#define SEND_CALLBACK ((void(*)(id, SEL, NSDocumentController *, BOOL, void *))objc_msgSend)

- (void)reviewUnsavedDocumentsWithAlertTitle:(NSString *)title cancellable:(BOOL)cancellable delegate:(id)delegate didReviewAllSelector:(SEL)didReviewAllSelector contextInfo:(void *)contextInfo
{
    if([_gameDocuments count] == 0)
    {
        [super reviewUnsavedDocumentsWithAlertTitle:title cancellable:cancellable delegate:delegate didReviewAllSelector:didReviewAllSelector contextInfo:contextInfo];
        return;
    }

    //if([[OEHUDAlert quitApplicationAlert] runModal] == NSAlertDefaultReturn)
    if (true)
        [self closeAllDocumentsWithDelegate:delegate didCloseAllSelector:didReviewAllSelector contextInfo:contextInfo];
    else
        SEND_CALLBACK(delegate, didReviewAllSelector, self, NO, contextInfo);
}

- (void)closeAllDocumentsWithDelegate:(id)delegate didCloseAllSelector:(SEL)didCloseAllSelector contextInfo:(void *)contextInfo
{
    if([_gameDocuments count] == 0)
    {
        [super closeAllDocumentsWithDelegate:delegate didCloseAllSelector:didCloseAllSelector contextInfo:contextInfo];
        return;
    }

    NSArray *gameDocuments = [_gameDocuments copy];
    __block NSInteger remainingDocuments = [gameDocuments count];
    for(OEGameDocument *document in gameDocuments)
    {
        [document canCloseDocumentWithCompletionHandler:
         ^(NSDocument *document, BOOL shouldClose)
         {
             remainingDocuments--;
             if(shouldClose) [document close];

             if(remainingDocuments > 0) return;

             if([_gameDocuments count] > 0)
                 SEND_CALLBACK(delegate, didCloseAllSelector, self, NO, contextInfo);
             else
                 [super closeAllDocumentsWithDelegate:delegate didCloseAllSelector:didCloseAllSelector contextInfo:contextInfo];
         }];
    }
#undef SEND_CALLBACK
}

- (void)OE_setupGameDocument:(OEGameDocument *)document display:(BOOL)displayDocument fullScreen:(BOOL)fullScreen completionHandler:(void (^)(OEGameDocument *document, NSError *error))completionHandler;
{
    [self addDocument:document];
    [document setupGameWithCompletionHandler:
     ^(BOOL success, NSError *error)
     {
         if(success)
         {
             if(displayDocument) [document showInSeparateWindowInFullScreen:fullScreen];
             if(completionHandler)  completionHandler(document, nil);
         }
         else if(completionHandler) completionHandler(nil, error);
     }];
}

- (void)reopenDocumentForURL:(NSURL *)urlOrNil withContentsOfURL:(NSURL *)contentsURL display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
	// Only restore previously-open documents if none are already open.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0), dispatch_get_main_queue(), ^{
	    [self OE_ensureInitialized];
		
		if ([_gameDocuments count] < 1) {
			[self openDocumentWithContentsOfURL:contentsURL display:displayDocument completionHandler:completionHandler];
		}
	});
}

- (void)openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
    [self OE_ensureInitialized];
    if (url == nil) {
        return;
    }

    // If this ROM is already open, bring its window to front
    NSURL *standardizedURL = [url URLByStandardizingPath];
    for(OEGameDocument *doc in _gameDocuments)
    {
        if([[[doc romFileURL] URLByStandardizingPath] isEqual:standardizedURL])
        {
            [[[doc gameWindowController] window] makeKeyAndOrderFront:nil];
            if(completionHandler) completionHandler(doc, YES, nil);
            return;
        }
    }

    [super openDocumentWithContentsOfURL:url display:NO completionHandler:
     ^(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error)
     {
         if([document isKindOfClass:[OEGameDocument class]])
         {
             [self OE_setupGameDocument:(OEGameDocument*)document display:YES fullScreen:NO completionHandler:nil];
         }
         
         if([[error domain] isEqualToString:OEGameDocumentErrorDomain] && [error code] == OEImportRequiredError)
         {
             if(completionHandler != nil) {
                 completionHandler(nil, NO, nil);
             }
             
             return;
         }
         
         if(completionHandler != nil) {
             completionHandler(document, documentWasAlreadyOpen, error);
         }
         
         //[[NSDocumentController sharedDocumentController] clearRecentDocuments:nil];
     }];
}

- (void)openGameDocumentWithRom:(OERom *)rom display:(BOOL)displayDocument fullScreen:(BOOL)fullScreen completionHandler:(void (^)(OEGameDocument *document, NSError *error))completionHandler;
{
    NSError *error = nil;
    OEGameDocument *document = [[OEGameDocument alloc] initWithRom:rom core:nil error:&error];

    if(document == nil)
    {
        completionHandler(nil, error);
        return;
    }

    [self OE_setupGameDocument:document display:displayDocument fullScreen:fullScreen completionHandler:completionHandler];
}

#pragma mark -
- (void)OE_loadPlugins
{
    [OEPlugin registerPluginClass:[OECorePlugin class]];
    [OEPlugin registerPluginClass:[OESystemPlugin class]];
    [OEPlugin registerPluginClass:[OECompositionPlugin class]];
    [OEPlugin registerPluginClass:[OECGShaderPlugin class]];
    [OEPlugin registerPluginClass:[OEGLSLShaderPlugin class]];
    [OEPlugin registerPluginClass:[OEMultipassShaderPlugin class]];

    // Register all system controllers with the bindings controller
    for(OESystemPlugin *plugin in [OESystemPlugin allPlugins])
        [OEBindingsController registerSystemController:[plugin controller]];

    // Preload composition plugins
    [OECompositionPlugin allPlugins];

    [[OECorePlugin class] addObserver:self forKeyPath:@"allPlugins" options:0xF context:_OEApplicationDelegateAllPluginsContext];
}

- (void)OE_setupHIDSupport
{
    // Setup OEBindingsController
    [OEBindingsController class];
    [OEDeviceManager sharedDeviceManager];
}
#pragma mark - Preferences Window

- (IBAction)showPreferencesWindow:(id)sender
{
}

#pragma mark - Help Menu
- (IBAction)showOEHelp:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:OEUserGuideURL]];
}

- (IBAction)showOEReleaseNotes:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:OEReleaseNotesURL]];
}

- (IBAction)showOEWebSite:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:OEWebSiteURL]];
}

- (IBAction)showOEIssues:(id)sender
{
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:OEFeedbackURL]];
}

#pragma mark - About Window

- (void)showAboutWindow:(id)sender
{
    [[self aboutWindow] center];
    [[self aboutWindow] makeKeyAndOrderFront:self];
}

- (NSString *)aboutCreditsPath
{
    return [[NSBundle mainBundle] pathForResource:@"Credits" ofType:@"rtf"];
}

- (IBAction)openWeblink:(id)sender
{
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@", [sender title]]];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Application Info

- (void)updateInfoPlist
{
    // TODO: Think of a way to register for document types without manipulating the plist
    // as it's generally bad to modify the bundle's contents and we may not have write access
    /*NSArray             *systemPlugins = [OESystemPlugin allPlugins];
    NSMutableDictionary *allTypes      = [NSMutableDictionary dictionaryWithCapacity:[systemPlugins count]];

    for(OESystemPlugin *plugin in systemPlugins)
    {
        NSMutableDictionary *systemDocument = [NSMutableDictionary dictionary];
        [[plugin supportedTypeExtensions] enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            [systemDocument setObject:@"OEGameDocument"                 forKey:@"NSDocumentClass"];
            [systemDocument setObject:@"Viewer"                         forKey:@"CFBundleTypeRole"];
            [systemDocument setObject:@"Owner"                          forKey:@"LSHandlerRank"];
            [systemDocument setObject:[NSArray arrayWithObject:@"????"] forKey:@"CFBundleTypeOSTypes"];
        }];

        [systemDocument setObject:[plugin supportedTypeExtensions] forKey:@"CFBundleTypeExtensions"];
        NSString *typeName = [NSString stringWithFormat:@"%@ Game", [plugin systemName]];
        [systemDocument setObject:typeName forKey:@"CFBundleTypeName"];
        [allTypes setObject:systemDocument forKey:typeName];
    }

    NSString *error = nil;
    NSPropertyListFormat format;

    NSString *infoPlistPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Contents/Info.plist"];
    NSData   *infoPlistXml  = [[NSFileManager defaultManager] contentsAtPath:infoPlistPath];
    NSMutableDictionary *infoPlist = [NSPropertyListSerialization propertyListFromData:infoPlistXml
                                                                      mutabilityOption:NSPropertyListMutableContainers
                                                                                format:&format
                                                                      errorDescription:&error];
    if(infoPlist == nil) NSLog(@"%@", error);

    NSArray *existingTypes = [infoPlist objectForKey:@"CFBundleDocumentTypes"];
    for(NSDictionary *type in existingTypes)
        [allTypes setObject:type forKey:[type objectForKey:@"CFBundleTypeName"]];
    [infoPlist setObject:[allTypes allValues] forKey:@"CFBundleDocumentTypes"];

    NSData *updated = [NSPropertyListSerialization dataFromPropertyList:infoPlist
                                                                 format:NSPropertyListXMLFormat_v1_0
                                                       errorDescription:&error];

    if(updated != nil)
        [updated writeToFile:infoPlistPath atomically:YES];
    else
        NSLog(@"Error: %@", error);*/
}

- (NSString *)appVersion
{
    return [[[NSBundle mainBundle] infoDictionary] valueForKey:@"CFBundleVersion"];
}

- (NSString *)buildVersion
{
    return BUILD_VERSION;
}

- (NSAttributedString *)projectURL
{
    return [NSAttributedString hyperlinkFromString:@"http://openemu.org" withURL:[NSURL URLWithString:@"http://openemu.org"]];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if(context == _OEApplicationDelegateAllPluginsContext)
        [self updateInfoPlist];
    else
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}


#pragma mark - Debug
- (void)setLogHIDEvents:(BOOL)value
{
    if(_logHIDEvents == value)
        return;

    _logHIDEvents = value;

    if(_HIDEventsMonitor != nil)
    {
        [[OEDeviceManager sharedDeviceManager] removeMonitor:_HIDEventsMonitor];
        _HIDEventsMonitor = nil;
    }

    if(_logHIDEvents)
    {
        _HIDEventsMonitor = [[OEDeviceManager sharedDeviceManager] addGlobalEventMonitorHandler:
                             ^ BOOL (OEDeviceHandler *handler, OEHIDEvent *event)
                             {
                                 if([event type] != OEHIDEventTypeKeyboard) NSLog(@"%@", event);
                                 return YES;
                             }];
    }
}

- (void)setLogKeyboardEvents:(BOOL)value
{
    if(_logKeyboardEvents == value)
        return;

    _logKeyboardEvents = value;

    if(_keyboardEventsMonitor != nil)
    {
        [[OEDeviceManager sharedDeviceManager] removeMonitor:_keyboardEventsMonitor];
        _keyboardEventsMonitor = nil;
    }

    if(_logKeyboardEvents)
    {
        _keyboardEventsMonitor = [[OEDeviceManager sharedDeviceManager] addGlobalEventMonitorHandler:
                                  ^ BOOL (OEDeviceHandler *handler, OEHIDEvent *event)
                                  {
                                      if([event type] == OEHIDEventTypeKeyboard) NSLog(@"%@", event);
                                      return YES;
                                  }];
    }
}

- (IBAction)OEDebug_logResponderChain:(id)sender;
{
    DLog(@"NSApp.KeyWindow: %@", [NSApp keyWindow]);
    LogResponderChain([[NSApp keyWindow] firstResponder]);
}

@end
