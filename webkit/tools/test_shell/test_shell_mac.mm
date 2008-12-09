// Copyright (c) 2006-2008 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#include <sys/stat.h>

#include "webkit/tools/test_shell/test_shell.h"

#include "base/basictypes.h"
#include "base/debug_on_start.h"
#include "base/debug_util.h"
#include "base/file_util.h"
#include "base/gfx/size.h"
#include "base/icu_util.h"
#include "base/mac_util.h"
#include "base/memory_debug.h"
#include "base/message_loop.h"
#include "base/path_service.h"
#include "base/stats_table.h"
#include "base/string_util.h"
#include "net/base/mime_util.h"
#include "skia/ext/bitmap_platform_device.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "webkit/glue/webdatasource.h"
#include "webkit/glue/webframe.h"
#include "webkit/glue/webkit_glue.h"
#include "webkit/glue/webkit_resources.h"
#include "webkit/glue/webpreferences.h"
#include "webkit/glue/weburlrequest.h"
#include "webkit/glue/webview.h"
#include "webkit/glue/webwidget.h"
#include "webkit/glue/plugins/plugin_list.h"
#include "webkit/tools/test_shell/mac/test_shell_webview.h"
#include "webkit/tools/test_shell/simple_resource_loader_bridge.h"
#include "webkit/tools/test_shell/test_navigation_controller.h"

#import "skia/include/SkBitmap.h"

#define MAX_LOADSTRING 100

#define BUTTON_WIDTH 72
#define URLBAR_HEIGHT  32

// Global Variables:

// Content area size for newly created windows.
const int kTestWindowWidth = 800;
const int kTestWindowHeight = 600;

// The W3C SVG layout tests use a different size than the other layout tests
const int kSVGTestWindowWidth = 480;
const int kSVGTestWindowHeight = 360;

// Hide the window offscreen when in layout test mode.  Mac OS X limits
// window positions to +/- 16000.
const int kTestWindowXLocation = -14000;
const int kTestWindowYLocation = -14000;

// Define static member variables
base::LazyInstance <std::map<gfx::WindowHandle, TestShell *> >
    TestShell::window_map_(base::LINKER_INITIALIZED);

// Receives notification that the window is closing so that it can start the
// tear-down process. Is responsible for deleting itself when done.
@interface WindowCloseDelegate : NSObject {
}
@end

@implementation WindowCloseDelegate

// Called when the window is about to close. Perform the self-destruction
// sequence by getting rid of the shell and removing it and the window from
// the various global lists. Instead of doing it here, however, we fire off
// a delayed call to |-cleanup:| to allow everything to get off the stack
// before we go deleting objects. By returning YES, we allow the window to be
// removed from the screen.
- (BOOL)windowShouldClose:(id)window {
  // Try to make the window go away, but it may not when running layout
  // tests due to the quirkyness of autorelease pools and having no main loop.
  [window autorelease];

  // clean ourselves up and do the work after clearing the stack of anything
  // that might have the shell on it.
  [self performSelectorOnMainThread:@selector(cleanup:) 
                         withObject:window 
                      waitUntilDone:NO];

  return YES;
}

// does the work of removing the window from our various bookkeeping lists
// and gets rid of the shell.
- (void)cleanup:(id)window {
  BOOL found = TestShell::RemoveWindowFromList(window);
  DCHECK(found);
  TestShell::DestroyAssociatedShell(window);

  [self release];
}

@end

// Mac-specific stuff to do when the dtor is called. Nothing to do in our
// case.
void TestShell::PlatformCleanUp() {
}

// static
void TestShell::DestroyAssociatedShell(gfx::WindowHandle handle) {
  TestShell* shell = window_map_.Get()[handle];
  if (shell)
    window_map_.Get().erase(handle);
  delete shell;
}

// static
void TestShell::PlatformShutdown() {
  // for each window in the window list, release it and destroy its shell
  for (WindowList::iterator it = TestShell::windowList()->begin();
       it != TestShell::windowList()->end();
       ++it) {
    DestroyAssociatedShell(*it);
    [*it release];
  }
  // assert if we have anything left over, that would be bad.
  DCHECK(window_map_.Get().size() == 0);
}

// static
void TestShell::InitializeTestShell(bool layout_test_mode) {
  window_list_ = new WindowList;
  layout_test_mode_ = layout_test_mode;
  
  web_prefs_ = new WebPreferences;
  
  ResetWebPreferences();

  // Load the Ahem font, which is used by layout tests.
  NSString* ahem_path = [[[NSBundle mainBundle] resourcePath]
      stringByAppendingPathComponent:@"AHEM____.TTF"];
  const char* ahem_path_c = [ahem_path fileSystemRepresentation];
  FSRef ahem_fsref;
  if (!mac_util::FSRefFromPath(ahem_path_c, &ahem_fsref)) {
    DCHECK(false) << "FSRefFromPath " << ahem_path_c;
  } else {
    // The last argument is an ATSFontContainerRef that can be passed to
    // ATSFontDeactivate to unload the font.  Since the font is only loaded
    // for this process, and it's always wanted, don't keep track of it.
    if (ATSFontActivateFromFileReference(&ahem_fsref,
                                         kATSFontContextLocal,
                                         kATSFontFormatUnspecified,
                                         NULL,
                                         kATSOptionFlagsDefault,
                                         NULL) != noErr) {
      DCHECK(false) << "ATSFontActivateFromFileReference " << ahem_path_c;
    }
  }
}

NSButton* MakeTestButton(NSRect* rect, NSString* title, NSView* parent) {
  NSButton* button = [[NSButton alloc] initWithFrame:*rect];
  [button setTitle:title];
  [button setBezelStyle:NSSmallSquareBezelStyle];
  [button setAutoresizingMask:(NSViewMaxXMargin | NSViewMinYMargin)];
  [parent addSubview:button];
  rect->origin.x += BUTTON_WIDTH;
  return button;
}

bool TestShell::Initialize(const std::wstring& startingURL) {
  // Perform application initialization:
  // send message to app controller?  need to work this out
  
  // TODO(awalker): this is a straight recreation of windows test_shell.cc's
  // window creation code--we should really pull this from the nib and grab
  // references to the already-created subviews that way.
  NSRect screen_rect = [[NSScreen mainScreen] visibleFrame];
  NSRect window_rect = { {0, screen_rect.size.height - kTestWindowHeight},
                         {kTestWindowWidth, kTestWindowHeight} };
  m_mainWnd = [[NSWindow alloc]
                  initWithContentRect:window_rect
                            styleMask:(NSTitledWindowMask |
                                       NSClosableWindowMask |
                                       NSMiniaturizableWindowMask |
                                       NSResizableWindowMask |
                                       NSTexturedBackgroundWindowMask)
                              backing:NSBackingStoreBuffered
                                defer:NO];
  [m_mainWnd setTitle:@"TestShell"];
  
  // Create a window delegate to watch for when it's asked to go away. It will
  // clean itself up so we don't need to hold a reference.
  [m_mainWnd setDelegate:[[WindowCloseDelegate alloc] init]];
  
  // Rely on the window delegate to clean us up rather than immediately 
  // releasing when the window gets closed. We use the delegate to do 
  // everything from the autorelease pool so the shell isn't on the stack
  // during cleanup (ie, a window close from javascript).
  [m_mainWnd setReleasedWhenClosed:NO];
  
  // Create a webview. Note that |web_view| takes ownership of this shell so we
  // will get cleaned up when it gets destroyed.
  m_webViewHost.reset(
      WebViewHost::Create(m_mainWnd, delegate_.get(), *TestShell::web_prefs_));
  webView()->SetUseEditorDelegate(true);
  delegate_->RegisterDragDrop();
  TestShellWebView* web_view = 
      static_cast<TestShellWebView*>(m_webViewHost->view_handle());
  [web_view setShell:this];
  
  // create buttons
  NSRect button_rect = [[m_mainWnd contentView] bounds];
  button_rect.origin.y = window_rect.size.height - 22;
  button_rect.size.height = 22;
  button_rect.origin.x += 16;
  button_rect.size.width = BUTTON_WIDTH;
  
  NSView* content = [m_mainWnd contentView];
  
  NSButton* button = MakeTestButton(&button_rect, @"Back", content);
  [button setTarget:web_view];
  [button setAction:@selector(goBack:)];
  
  button = MakeTestButton(&button_rect, @"Forward", content);
  [button setTarget:web_view];
  [button setAction:@selector(goForward:)];
  
  // reload button
  button = MakeTestButton(&button_rect, @"Reload", content);
  [button setTarget:web_view];
  [button setAction:@selector(reload:)];
  
  // stop button
  button = MakeTestButton(&button_rect, @"Stop", content);
  [button setTarget:web_view];
  [button setAction:@selector(stopLoading:)];
  
  // text field for URL
  button_rect.origin.x += 16;
  button_rect.size.width = [[m_mainWnd contentView] bounds].size.width -
  button_rect.origin.x - 32;
  m_editWnd = [[NSTextField alloc] initWithFrame:button_rect];
  [[m_mainWnd contentView] addSubview:m_editWnd];
  [m_editWnd setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  [m_editWnd setTarget:web_view];
  [m_editWnd setAction:@selector(takeURLStringValueFrom:)];
  [[m_editWnd cell] setWraps:NO];
  [[m_editWnd cell] setScrollable:YES];

  // show the window
  [m_mainWnd makeKeyAndOrderFront: nil];
  
  // Load our initial content.
  if (!startingURL.empty())
    LoadURL(startingURL.c_str());

  bool bIsSVGTest = startingURL.find(L"W3C-SVG-1.1") != std::wstring::npos;

  if (bIsSVGTest) {
    SizeTo(kSVGTestWindowWidth, kSVGTestWindowHeight);
  } else {
    SizeToDefault();
  }

  return true;
}

void TestShell::TestFinished() {
  if (!test_is_pending_)
    return;  // reached when running under test_shell_tests
  
  test_is_pending_ = false;
  MessageLoop::current()->Quit();
}

// A class to be the target/selector of the "watchdog" thread that ensures
// pages timeout if they take too long and tells the test harness via stdout.
@interface WatchDogTarget : NSObject {
 @private
  NSTimeInterval timeout_;
}
// |timeout| is in seconds
- (id)initWithTimeout:(NSTimeInterval)timeout;
// serves as the "run" method of a NSThread.
- (void)run:(id)sender;
@end

@implementation WatchDogTarget

- (id)initWithTimeout:(NSTimeInterval)timeout {
  if ((self = [super init])) {
    timeout_ = timeout;
  }
  return self;
}

- (void)run:(id)ignore {
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  
  // check for debugger, just bail if so. We don't want the timeouts hitting
  // when we're trying to track down an issue.
  if (DebugUtil::BeingDebugged())
    return;
    
  NSThread* currentThread = [NSThread currentThread];
  
  // Wait to be cancelled. If we are that means the test finished. If it hasn't,
  // then we need to tell the layout script we timed out and start again.
  NSDate* limitDate = [NSDate dateWithTimeIntervalSinceNow:timeout_];
  while ([(NSDate*)[NSDate date] compare:limitDate] == NSOrderedAscending &&
         ![currentThread isCancelled]) {
    // sleep for a small increment then check again
    NSDate* incrementDate = [NSDate dateWithTimeIntervalSinceNow:1.0];
    [NSThread sleepUntilDate:incrementDate];
  }
  if (![currentThread isCancelled]) {
    // Print a warning to be caught by the layout-test script.
    // Note: the layout test driver may or may not recognize
    // this as a timeout.
    puts("#TEST_TIMED_OUT\n");
    puts("#EOF\n");
    fflush(stdout);
    abort();
  }

  [pool release];
}

@end

void TestShell::WaitTestFinished() {
  DCHECK(!test_is_pending_) << "cannot be used recursively";
  
  test_is_pending_ = true;
  
  // Create a watchdog thread which just sets a timer and
  // kills the process if it times out.  This catches really
  // bad hangs where the shell isn't coming back to the 
  // message loop.  If the watchdog is what catches a 
  // timeout, it can't do anything except terminate the test
  // shell, which is unfortunate.
  // Windows multiplies by 2.5, but that causes us to run for far, far too
  // long. We can adjust it down later if we need to.
  NSTimeInterval timeout_seconds = GetLayoutTestTimeoutInSeconds();
  WatchDogTarget* watchdog = [[[WatchDogTarget alloc] 
                                initWithTimeout:timeout_seconds] autorelease];
  NSThread* thread = [[NSThread alloc] initWithTarget:watchdog
                                             selector:@selector(run:) 
                                               object:nil];
  [thread start];
  
  // TestFinished() will post a quit message to break this loop when the page
  // finishes loading.
  while (test_is_pending_)
    MessageLoop::current()->Run();

  // Tell the watchdog that we're finished. No point waiting to re-join, it'll
  // die on its own.
  [thread cancel];
  [thread release];
}

void TestShell::InteractiveSetFocus(WebWidgetHost* host, bool enable) {
#if 0
  if (enable)
    ::SetFocus(host->view_handle());
  else if (::GetFocus() == host->view_handle())
    ::SetFocus(NULL);
#endif
}

// static*
bool TestShell::CreateNewWindow(const std::wstring& startingURL,
                                TestShell** result) {
  TestShell* shell = new TestShell();
  bool rv = shell->Initialize(startingURL);
  if (rv) {
    if (result)
      *result = shell;
    TestShell::windowList()->push_back(shell->m_mainWnd);
    window_map_.Get()[shell->m_mainWnd] = shell;
  }
  return rv;
}

// static
void TestShell::DestroyWindow(gfx::WindowHandle windowHandle) {
  // Do we want to tear down some of the machinery behind the scenes too?
  [windowHandle performClose:nil];
}

WebWidget* TestShell::CreatePopupWidget(WebView* webview) {
  DCHECK(!m_popupHost);
  m_popupHost = WebWidgetHost::Create(NULL, delegate_.get());
  // ShowWindow(popupWnd(), SW_SHOW);
  
  return m_popupHost->webwidget();
}

void TestShell::ClosePopup() {
  // PostMessage(popupWnd(), WM_CLOSE, 0, 0);
  m_popupHost = NULL;
}

void TestShell::SizeTo(int width, int height) {
  // WebViewHost::Create() sets the HTML content rect to start 32 pixels below
  // the top of the window to account for the "toolbar". We need to match that
  // here otherwise the HTML content area will be too short.
  NSRect r = [m_mainWnd contentRectForFrameRect:[m_mainWnd frame]];
  r.size.width = width;
  r.size.height = height + URLBAR_HEIGHT;
  [m_mainWnd setFrame:[m_mainWnd frameRectForContentRect:r] display:YES];
}

void TestShell::ResizeSubViews() {
  // handled by Cocoa for us
}

/* static */ void TestShell::DumpBackForwardList(std::wstring* result) {
  result->clear();
  for (WindowList::iterator iter = TestShell::windowList()->begin();
       iter != TestShell::windowList()->end(); iter++) {
    NSWindow* window = *iter;
    TestShell* shell = window_map_.Get()[window];
    if (shell)
      webkit_glue::DumpBackForwardList(shell->webView(), NULL, result);
  }
}

/* static */ bool TestShell::RunFileTest(const char* filename,
                                         const TestParams& params) {
  // Load the test file into the first available window.
  if (TestShell::windowList()->empty()) {
    LOG(ERROR) << "No windows open.";
    return false;
  }

  NSWindow* window = *(TestShell::windowList()->begin());
  TestShell* shell = window_map_.Get()[window];
  shell->ResetTestController();

  // ResetTestController may have closed the window we were holding on to. 
  // Grab the first window again.
  window = *(TestShell::windowList()->begin());
  shell = window_map_.Get()[window];
  DCHECK(shell);

  // Clear focus between tests.
  shell->m_focusedWidgetHost = NULL;

  // Make sure the previous load is stopped.
  shell->webView()->StopLoading();
  shell->navigation_controller()->Reset();

  // Clean up state between test runs.
  webkit_glue::ResetBeforeTestRun(shell->webView());
  ResetWebPreferences();
  shell->webView()->SetPreferences(*web_prefs_);

  // Hide the window. We can't actually use NSWindow's |-setFrameTopLeftPoint:|
  // because it leaves a chunk of the window visible instead of moving it
  // offscreen.
  [shell->m_mainWnd orderOut:nil];
  shell->ResizeSubViews();

  if (strstr(filename, "loading/"))
    shell->layout_test_controller()->SetShouldDumpFrameLoadCallbacks(true);

  shell->test_is_preparing_ = true;

  shell->LoadURL(UTF8ToWide(filename).c_str());

  shell->test_is_preparing_ = false;
  shell->WaitTestFinished();

  // Echo the url in the output so we know we're not getting out of sync.
  printf("#URL:%s\n", filename);

  // Dump the requested representation.
  WebFrame* webFrame = shell->webView()->GetMainFrame();
  if (webFrame) {
    bool should_dump_as_text =
        shell->layout_test_controller_->ShouldDumpAsText();
    bool dumped_anything = false;
    if (params.dump_tree) {
      dumped_anything = true;
      // Text output: the test page can request different types of output
      // which we handle here.
      if (!should_dump_as_text) {
        // Plain text pages should be dumped as text
        std::string mime_type =
            WideToUTF8(webFrame->GetDataSource()->GetResponseMimeType());
        should_dump_as_text = (mime_type == "text/plain");
      }
      if (should_dump_as_text) {
        bool recursive = shell->layout_test_controller_->
            ShouldDumpChildFramesAsText();
        printf("%s", WideToUTF8(
            webkit_glue::DumpFramesAsText(webFrame, recursive)).
            c_str());
      } else {
        printf("%s", WideToUTF8(
            webkit_glue::DumpRenderer(webFrame)).c_str());

        bool recursive = shell->layout_test_controller_->
            ShouldDumpChildFrameScrollPositions();
        printf("%s", WideToUTF8(
            webkit_glue::DumpFrameScrollPosition(webFrame, recursive)).
            c_str());
      }

      if (shell->layout_test_controller_->ShouldDumpBackForwardList()) {
        std::wstring bfDump;
        DumpBackForwardList(&bfDump);
        printf("%s", WideToUTF8(bfDump).c_str());
      }
    }
    
    if (params.dump_pixels && !should_dump_as_text) {
      // Image output: we write the image data to the file given on the
      // command line (for the dump pixels argument), and the MD5 sum to
      // stdout.
      dumped_anything = true;
      std::string md5sum = DumpImage(webFrame, params.pixel_file_name);
      printf("#MD5:%s\n", md5sum.c_str());
    }
    if (dumped_anything)
      printf("#EOF\n");
    fflush(stdout);
  }

  return true;
}

void TestShell::LoadURLForFrame(const wchar_t* url,
                                const wchar_t* frame_name) {
  if (!url)
    return;
  
  std::string url8 = WideToUTF8(url);

  bool bIsSVGTest = strstr(url8.c_str(), "W3C-SVG-1.1") > 0;

  if (bIsSVGTest) {
    SizeTo(kSVGTestWindowWidth, kSVGTestWindowHeight);
  } else {
    // only resize back to the default when running tests
    if (layout_test_mode())
      SizeToDefault();
  }

  std::string urlString(url8);
  struct stat stat_buf;
  if (!urlString.empty() && stat(url8.c_str(), &stat_buf) == 0) {
    urlString.insert(0, "file://");
  }

  std::wstring frame_string;
  if (frame_name)
    frame_string = frame_name;

  navigation_controller_->LoadEntry(new TestNavigationEntry(
      -1, GURL(urlString), std::wstring(), frame_string));
}

bool TestShell::PromptForSaveFile(const wchar_t* prompt_title,
                                  std::wstring* result)
{
  NSSavePanel* save_panel = [NSSavePanel savePanel];
  
  /* set up new attributes */
  [save_panel setRequiredFileType:@"txt"];
  [save_panel setMessage:
      [NSString stringWithUTF8String:WideToUTF8(prompt_title).c_str()]];
  
  /* display the NSSavePanel */
  if ([save_panel runModalForDirectory:NSHomeDirectory() file:@""] ==
      NSOKButton) {
    result->assign(UTF8ToWide([[save_panel filename] UTF8String]));
    return true;
  }
  return false;
}

static void WriteTextToFile(const std::string& data,
                            const std::string& file_path)
{
  FILE* fp = fopen(file_path.c_str(), "w");
  if (!fp)
    return;
  fwrite(data.c_str(), sizeof(std::string::value_type), data.size(), fp);
  fclose(fp);
}

void TestShell::DumpDocumentText()
{
  std::wstring file_path;
  if (!PromptForSaveFile(L"Dump document text", &file_path))
    return;

  WriteTextToFile(
      WideToUTF8(webkit_glue::DumpDocumentText(webView()->GetMainFrame())),
      WideToUTF8(file_path));
}

void TestShell::DumpRenderTree()
{
  std::wstring file_path;
  if (!PromptForSaveFile(L"Dump render tree", &file_path))
    return;

  WriteTextToFile(
      WideToUTF8(webkit_glue::DumpRenderer(webView()->GetMainFrame())),
      WideToUTF8(file_path));
}

// static
std::string TestShell::RewriteLocalUrl(const std::string& url) {
  // Convert file:///tmp/LayoutTests urls to the actual location on disk.
  const char kPrefix[] = "file:///tmp/LayoutTests/";
  const int kPrefixLen = arraysize(kPrefix) - 1;

  std::string new_url(url);
  if (url.compare(0, kPrefixLen, kPrefix, kPrefixLen) == 0) {
    FilePath replace_path;
    PathService::Get(base::DIR_EXE, &replace_path);
    replace_path = replace_path.DirName().DirName().Append(
        "webkit/data/layout_tests/LayoutTests/");
    new_url = std::string("file://") + replace_path.value() +
        url.substr(kPrefixLen);
  }

  return new_url;
}

// static
void TestShell::ShowStartupDebuggingDialog() {
  // TODO(port): Show a modal dialog here with an attach to me message.
}

//-----------------------------------------------------------------------------

namespace webkit_glue {

std::wstring GetLocalizedString(int message_id) {
  NSString* idString = [NSString stringWithFormat:@"%d", message_id];
  NSString* localString = NSLocalizedString(idString, @"");

  return UTF8ToWide([localString UTF8String]);
}

NSCursor* LoadCursor(int cursor_id) {
  // TODO(port): add some more options here
  return [NSCursor arrowCursor];
}

bool GetInspectorHTMLPath(std::string* path) {
  NSString* resource_path = [[NSBundle mainBundle] resourcePath];
  if (!resource_path)
    return false;
  *path = [resource_path UTF8String];
  *path += "/Inspector/inspector.htm";
  return true;
}

bool GetPlugins(bool refresh, std::vector<WebPluginInfo>* plugins) {
  return false; // NPAPI::PluginList::Singleton()->GetPlugins(refresh, plugins);
}

ScreenInfo GetScreenInfo(gfx::ViewHandle window) {
  // This should call GetScreenInfoHelper, which should be implemented in
  // webkit_glue_mac.mm
  NOTIMPLEMENTED();
  return ScreenInfo();
}

bool DownloadUrl(const std::string& url, NSWindow* caller_window) {
  return false;
}

void DidLoadPlugin(const std::string& filename) {
}

void DidUnloadPlugin(const std::string& filename) {
}

}  // namespace webkit_glue
