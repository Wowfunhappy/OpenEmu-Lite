/*
 Copyright (c) 2026, OpenEmu Team

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

#import "OECheatsWindowController.h"
#import "OEGameDocument.h"
#import "OERom.h"
#import "OEUtilities.h"

#pragma mark - Column identifiers

static NSString *const OECheatDescriptionColumn = @"description";
static NSString *const OECheatCodeColumn        = @"code";

#pragma mark - Table view (double-click empty row to add, Delete key to remove)

@protocol OECheatsTableViewDelegate <NSTableViewDelegate>
- (void)cheatsTableViewDidDoubleClickEmptyArea:(NSTableView *)tableView;
- (void)cheatsTableView:(NSTableView *)tableView deleteRow:(NSInteger)row;
@end

@interface OECheatsTableView : NSTableView
@end

@implementation OECheatsTableView

// Double-clicking the empty area below the last cheat adds a new one. A single
// click there just clears the selection, matching normal AppKit table behavior.
- (void)mouseDown:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    if([self rowAtPoint:point] < 0)
    {
        if([event clickCount] >= 2)
        {
            id<OECheatsTableViewDelegate> delegate = (id<OECheatsTableViewDelegate>)[self delegate];
            if([delegate respondsToSelector:@selector(cheatsTableViewDidDoubleClickEmptyArea:)])
                [delegate cheatsTableViewDidDoubleClickEmptyArea:self];
        }
        else
        {
            [self deselectAll:nil];
        }
        return;
    }

    [super mouseDown:event];
}

// Delete/Backspace (or fn-Delete) removes the selected cheat, as long as a cell
// isn't being edited (the field editor would otherwise be first responder and
// handle the key itself, deleting a character rather than the row).
- (void)keyDown:(NSEvent *)event
{
    unsigned short keyCode = [event keyCode];
    BOOL isDeleteKey = (keyCode == 51 /* kVK_Delete (Backspace) */ || keyCode == 117 /* kVK_ForwardDelete */);

    if(isDeleteKey && [self selectedRow] >= 0)
    {
        id<OECheatsTableViewDelegate> delegate = (id<OECheatsTableViewDelegate>)[self delegate];
        if([delegate respondsToSelector:@selector(cheatsTableView:deleteRow:)])
        {
            [delegate cheatsTableView:self deleteRow:[self selectedRow]];
            return;
        }
    }

    [super keyDown:event];
}

#pragma mark - Empty-area tooltip

// Keeps a tooltip over the empty area below the last cheat, reflecting the
// current row count. Recomputed whenever the data or the view's size changes.
- (void)OE_updateEmptyAreaToolTip
{
    [self removeAllToolTips];

    NSInteger rows = [self numberOfRows];
    CGFloat usedHeight = rows * ([self rowHeight] + [self intercellSpacing].height);
    NSRect bounds = [self bounds];

    if(usedHeight < bounds.size.height)
    {
        NSRect emptyRect = NSMakeRect(0, usedHeight, bounds.size.width, bounds.size.height - usedHeight);
        [self addToolTipRect:emptyRect owner:self userData:NULL];
    }
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data
{
    return OELocalizedString(@"Double-click to add a cheat", @"Cheats table empty-area tooltip");
}

- (void)reloadData
{
    [super reloadData];
    [self OE_updateEmptyAreaToolTip];
}

- (void)setFrameSize:(NSSize)newSize
{
    [super setFrameSize:newSize];
    [self OE_updateEmptyAreaToolTip];
}

@end

@interface OECheatsWindowController () <NSTableViewDataSource, OECheatsTableViewDelegate, NSWindowDelegate>
@property(nonatomic, weak) OEGameDocument *gameDocument;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSButton *removeButton;
// While this panel is key, the menu bar is reduced to just the app menu and a
// standard Edit menu; every other top-level menu is removed and restored when
// the panel isn't key, so the rest of the (text-field-free) app is unaffected.
@property(nonatomic, strong) NSMenuItem *editMenuItem;
@property(nonatomic, strong) NSArray *savedMenuItems;
@end

@implementation OECheatsWindowController

+ (instancetype)sharedController
{
    static OECheatsWindowController *sharedController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedController = [[self alloc] init];
    });
    return sharedController;
}

- (instancetype)init
{
    return [super initWithWindow:[self OE_makeWindow]];
}

- (NSWindow *)OE_makeWindow
{
    NSRect contentRect = NSMakeRect(0, 0, 600, 300);
    // A utility panel so it never becomes the *main* window; the dynamic Cheats
    // submenu resolves the front document via -[NSApp mainWindow], which must
    // stay pointed at the game window even while this manager is key.
    NSPanel *window = [[NSPanel alloc] initWithContentRect:contentRect
                                                 styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask | NSUtilityWindowMask)
                                                   backing:NSBackingStoreBuffered
                                                     defer:YES];
    [window setReleasedWhenClosed:NO];
    [window setMinSize:NSMakeSize(600, 200)];
    [window setTitle:OELocalizedString(@"Manage Cheats", @"Cheats window title")];
    [window setDelegate:self];

    NSView *content = [window contentView];

    // Table inside a scroll view, with a +/−/Done button row along the bottom.
    // A cheat can also be added by double-clicking the empty area below the
    // last row, or removed by selecting it and pressing Delete (or clearing
    // both its fields).
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 40, contentRect.size.width, contentRect.size.height - 40)];
    [scrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [scrollView setHasVerticalScroller:YES];
    [scrollView setBorderType:NSBezelBorder];

    OECheatsTableView *table = [[OECheatsTableView alloc] initWithFrame:[[scrollView contentView] bounds]];
    [table setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [table setUsesAlternatingRowBackgroundColors:YES];
    [table setColumnAutoresizingStyle:NSTableViewLastColumnOnlyAutoresizingStyle];
    [table setAllowsMultipleSelection:NO];

    // Title column. (Whether a cheat is on or off is controlled from the
    // Emulation ▸ Cheats submenu, not here.)
    NSTableColumn *titleColumn = [[NSTableColumn alloc] initWithIdentifier:OECheatDescriptionColumn];
    [[titleColumn headerCell] setStringValue:OELocalizedString(@"Title", @"Cheats table 'title' column header")];
    [titleColumn setWidth:180];
    [titleColumn setEditable:YES];
    [table addTableColumn:titleColumn];

    // Code column. It's the last column, so NSTableViewLastColumnOnlyAutoresizingStyle
    // (set below) keeps it filling any extra width as the window is resized; give
    // it a wide starting width here so it already fills the default window size.
    NSTableColumn *codeColumn = [[NSTableColumn alloc] initWithIdentifier:OECheatCodeColumn];
    [[codeColumn headerCell] setStringValue:OELocalizedString(@"Code", @"Cheats table 'code' column header")];
    [codeColumn setWidth:396];
    [codeColumn setEditable:YES];
    [table addTableColumn:codeColumn];

    [table setDataSource:self];
    [table setDelegate:self];
    [scrollView setDocumentView:table];
    [content addSubview:scrollView];
    _tableView = table;

    // Add / remove buttons along the bottom: a joined pair of small square
    // buttons using the standard +/− template images.
    NSButton *addButton = [[NSButton alloc] initWithFrame:NSMakeRect(8, 8, 25, 23)];
    [addButton setBezelStyle:NSSmallSquareBezelStyle];
    [addButton setButtonType:NSMomentaryPushInButton];
    [addButton setImage:[NSImage imageNamed:NSImageNameAddTemplate]];
    [addButton setImagePosition:NSImageOnly];
    [addButton setBordered:YES];
    [addButton setTarget:self];
    [addButton setAction:@selector(addCheat:)];
    [addButton setAutoresizingMask:NSViewMaxXMargin];
    [content addSubview:addButton];

    NSButton *removeButton = [[NSButton alloc] initWithFrame:NSMakeRect(32, 8, 25, 23)];
    [removeButton setBezelStyle:NSSmallSquareBezelStyle];
    [removeButton setButtonType:NSMomentaryPushInButton];
    [removeButton setImage:[NSImage imageNamed:NSImageNameRemoveTemplate]];
    [removeButton setImagePosition:NSImageOnly];
    [removeButton setBordered:YES];
    [removeButton setTarget:self];
    [removeButton setAction:@selector(removeCheat:)];
    [removeButton setAutoresizingMask:NSViewMaxXMargin];
    [content addSubview:removeButton];
    _removeButton = removeButton;

    NSButton *doneButton = [[NSButton alloc] initWithFrame:NSMakeRect(contentRect.size.width - 88, 6, 80, 28)];
    [doneButton setBezelStyle:NSRoundedBezelStyle];
    [doneButton setTitle:OELocalizedString(@"Done", @"")];
    [doneButton setTarget:self];
    [doneButton setAction:@selector(done:)];
    [doneButton setKeyEquivalent:@"\r"];
    [doneButton setAutoresizingMask:NSViewMinXMargin];
    [content addSubview:doneButton];

    return window;
}

#pragma mark - Presentation

- (void)showCheatsForDocument:(OEGameDocument *)document
{
    [self setGameDocument:document];

    NSString *name = [[document rom] name];
    if([name length] > 0)
        [[self window] setTitle:[NSString stringWithFormat:OELocalizedString(@"Manage Cheats — %@", @"Cheats window title with ROM name"), name]];
    else
        [[self window] setTitle:OELocalizedString(@"Manage Cheats", @"Cheats window title")];

    [[self tableView] reloadData];
    [self OE_updateRemoveButton];
    [self showWindow:nil];
    [[self window] makeKeyAndOrderFront:nil];
}

- (void)OE_updateRemoveButton
{
    [[self removeButton] setEnabled:([[self tableView] selectedRow] >= 0)];
}

#pragma mark - Actions

- (void)OE_addCheatAndEditTitle
{
    OEGameDocument *document = [self gameDocument];
    if(document == nil) return;

    [document addNewCheat];
    [[self tableView] reloadData];

    NSInteger row = (NSInteger)[[document cheats] count] - 1;
    if(row >= 0)
    {
        [[self tableView] selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        // Let the user name the new cheat straight away.
        [[self tableView] editColumn:[[self tableView] columnWithIdentifier:OECheatDescriptionColumn] row:row withEvent:nil select:YES];
    }
    [self OE_updateRemoveButton];
}

- (void)OE_removeCheatAtRow:(NSInteger)row
{
    OEGameDocument *document = [self gameDocument];
    if(document == nil || row < 0 || row >= (NSInteger)[[document cheats] count]) return;

    [document removeCheatAtIndex:(NSUInteger)row];
    [[self tableView] reloadData];
    [self OE_updateRemoveButton];
}

- (IBAction)addCheat:(id)sender
{
    [self OE_addCheatAndEditTitle];
}

- (IBAction)removeCheat:(id)sender
{
    [self OE_removeCheatAtRow:[[self tableView] selectedRow]];
}

- (IBAction)done:(id)sender
{
    [[self window] performClose:sender];
}

#pragma mark - OECheatsTableViewDelegate

// Double-clicking the empty area below the last cheat adds a new one.
- (void)cheatsTableViewDidDoubleClickEmptyArea:(NSTableView *)tableView
{
    [self OE_addCheatAndEditTitle];
}

// The Delete key removes the selected cheat outright.
- (void)cheatsTableView:(NSTableView *)tableView deleteRow:(NSInteger)row
{
    [self OE_removeCheatAtRow:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    [self OE_updateRemoveButton];
}

#pragma mark - NSTableViewDataSource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[[[self gameDocument] cheats] count];
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSArray *cheats = [[self gameDocument] cheats];
    if(row < 0 || row >= (NSInteger)[cheats count]) return nil;

    NSDictionary *cheat = [cheats objectAtIndex:row];
    return [cheat objectForKey:[tableColumn identifier]];
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    OEGameDocument *document = [self gameDocument];
    NSMutableArray *cheats = [document cheats];
    if(row < 0 || row >= (NSInteger)[cheats count]) return;

    NSMutableDictionary *cheat = [cheats objectAtIndex:row];
    NSString *identifier = [tableColumn identifier];

    [cheat setObject:(object ?: @"") forKey:identifier];

    // A cheat with neither a title nor a code is meaningless — drop it.
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *title = [[cheat objectForKey:@"description"] stringByTrimmingCharactersInSet:whitespace];
    NSString *code  = [[cheat objectForKey:@"code"] stringByTrimmingCharactersInSet:whitespace];
    if([title length] == 0 && [code length] == 0)
    {
        [self OE_removeCheatAtRow:row];
        return;
    }

    // If the code of an already-enabled cheat is edited, push it to the core.
    if([identifier isEqualToString:OECheatCodeColumn] && [[cheat objectForKey:@"enabled"] boolValue])
        [document setCheat:[cheat objectForKey:@"code"] withType:[cheat objectForKey:@"type"] enabled:YES];

    [document saveCheats];
}

#pragma mark - Contextual Edit menu

// A standard Edit menu, present only while this panel is key so the user can
// cut/copy/paste (and use ⌘X/C/V/A) in the Title and Code fields. The items
// target the first responder, so AppKit enables/disables them automatically
// based on the field editor's selection.
- (NSMenu *)OE_makeEditMenu
{
    NSMenu *menu = [[NSMenu alloc] initWithTitle:OELocalizedString(@"Edit", @"")];

    [menu addItemWithTitle:OELocalizedString(@"Undo", @"") action:@selector(undo:) keyEquivalent:@"z"];

    NSMenuItem *redo = [menu addItemWithTitle:OELocalizedString(@"Redo", @"") action:@selector(redo:) keyEquivalent:@"z"];
    [redo setKeyEquivalentModifierMask:NSCommandKeyMask | NSShiftKeyMask];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:OELocalizedString(@"Cut", @"")   action:@selector(cut:)   keyEquivalent:@"x"];
    [menu addItemWithTitle:OELocalizedString(@"Copy", @"")  action:@selector(copy:)  keyEquivalent:@"c"];
    [menu addItemWithTitle:OELocalizedString(@"Paste", @"") action:@selector(paste:) keyEquivalent:@"v"];
    [menu addItemWithTitle:OELocalizedString(@"Delete", @"") action:@selector(delete:) keyEquivalent:@""];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:OELocalizedString(@"Select All", @"") action:@selector(selectAll:) keyEquivalent:@"a"];

    return menu;
}

// Reduces the menu bar to just the app menu (index 0, left untouched) and Edit:
// every other top-level item (File, Emulation, View, Window, Help, …) is pulled
// out and stashed so it can be put back exactly as it was.
- (void)OE_installEditMenu
{
    if(_editMenuItem != nil) return;

    NSMenu *mainMenu = [NSApp mainMenu];

    NSMutableArray *saved = [NSMutableArray array];
    while([mainMenu numberOfItems] > 1)
    {
        NSMenuItem *item = [mainMenu itemAtIndex:1];
        [saved addObject:item];
        [mainMenu removeItemAtIndex:1];
    }
    _savedMenuItems = saved;

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [editItem setTitle:OELocalizedString(@"Edit", @"")];
    [editItem setSubmenu:[self OE_makeEditMenu]];
    [mainMenu addItem:editItem];
    _editMenuItem = editItem;
}

- (void)OE_removeEditMenu
{
    if(_editMenuItem == nil) return;

    NSMenu *mainMenu = [NSApp mainMenu];
    [mainMenu removeItem:_editMenuItem];
    _editMenuItem = nil;

    for(NSMenuItem *item in _savedMenuItems)
        [mainMenu addItem:item];
    _savedMenuItems = nil;
}

#pragma mark - NSWindowDelegate

- (void)windowDidBecomeKey:(NSNotification *)notification
{
    [self OE_installEditMenu];
}

- (void)windowDidResignKey:(NSNotification *)notification
{
    [self OE_removeEditMenu];
}

- (void)windowWillClose:(NSNotification *)notification
{
    [self OE_removeEditMenu];
}

@end

#pragma mark - Dynamic Emulation ▸ Cheats submenu

@implementation OECheatsMenuDelegate

+ (instancetype)sharedDelegate
{
    static OECheatsMenuDelegate *sharedDelegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedDelegate = [[self alloc] init];
    });
    return sharedDelegate;
}

// The frontmost window drives the menu, so switching between documents shows the
// cheats belonging to whichever game is in focus.
- (OEGameDocument *)OE_frontGameDocument
{
    NSWindow *window   = ([NSApp mainWindow] ? : [NSApp keyWindow]);
    id document        = [[window windowController] document];

    if([document isKindOfClass:[OEGameDocument class]])
        return document;

    return nil;
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    // Rebuilt every time the submenu opens so it always reflects the current
    // front document's cheat list and each cheat's on/off state.
    [menu removeAllItems];

    // "Manage Cheats…" is always present. Its nil target routes through the
    // responder chain to the front OEGameDocument, which enables/disables it
    // via validateMenuItem: depending on whether the core supports cheats.
    NSMenuItem *manageItem = [[NSMenuItem alloc] initWithTitle:OELocalizedString(@"Manage Cheats…", @"")
                                                        action:@selector(manageCheats:)
                                                 keyEquivalent:@""];
    [menu addItem:manageItem];

    OEGameDocument *document = [self OE_frontGameDocument];
    if(document == nil || ![document supportsCheats])
        return;

    NSArray *cheats = [document cheats];
    if([cheats count] == 0)
        return;

    // Separator between "Manage Cheats…" and the cheats themselves.
    [menu addItem:[NSMenuItem separatorItem]];

    for(NSDictionary *cheat in cheats)
    {
        NSString *title = [cheat objectForKey:@"description"];
        if([title length] == 0) title = OELocalizedString(@"Untitled Cheat", @"");

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(setCheat:) keyEquivalent:@""];
        [item setRepresentedObject:cheat];
        [item setState:([[cheat objectForKey:@"enabled"] boolValue] ? NSOnState : NSOffState)];
        [menu addItem:item];
    }
}

@end
