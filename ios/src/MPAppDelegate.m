// Launcher and iOS glue for the zelda3 port.
//
// SDL's UIKit integration starts the game by calling
// -[SDLUIKitDelegate postFinishLaunch]. ios_main.c passes zelda3_main as the
// game entry point, and this delegate gates the call: the game starts from
// the launcher's JUGAR button, once a valid ROM sits in the app's Documents
// folder. That folder is also the game's working directory, so zelda3.ini,
// zelda3_assets.bps/zelda3_assets.dat and saves/ live there and stay visible
// in the Files app.
#import "MPAppDelegate.h"
#import "MPTouchControls.h"
#import "SDL_uikitappdelegate.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int zelda3_main(int argc, char **argv);  // src/main.c via patch 0011
void ZeldaWriteSram(void);               // zelda_rtl.h

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MDRomState) {
  MDRomMissing,
  MDRomInvalid,
  MDRomOk,
};

// Private of SDLUIKitDelegate (declared in its .m): runs the game.
@interface SDLUIKitDelegate (MPPrivate)
- (void)postFinishLaunch;
@end

// SDL resolves its delegate class with this class method; SDL_uikitappdelegate.h
// documents overriding it from a category on SDLUIKitDelegate itself.
@implementation SDLUIKitDelegate (MPAppDelegateClassName)
+ (NSString *)getAppDelegateClassName {
  return @"MPAppDelegate";
}
@end

@class MPAppDelegate;

@interface MPLauncherViewController : UIViewController
@property (nonatomic, weak, nullable) MPAppDelegate *appDelegate;
- (void)reloadState;
- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message;
@end

@interface MPAppDelegate () <UIDocumentPickerDelegate>
@property (nonatomic, strong, nullable) UIWindow *launcherWindow;
@property (nonatomic, strong, nullable) MPTouchControls *touchControls;
@property (nonatomic, assign) MDRomState romState;
@property (nonatomic, assign) BOOL gameRunning;
@property (nonatomic, readonly, nullable) MPLauncherViewController *launcherViewController;
- (void)startGame;
- (void)presentRomPicker;
@end

static NSString *MDDocumentsPath(void) {
  NSArray<NSString *> *paths =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  return paths.firstObject ?: NSTemporaryDirectory();
}

// Standard CRC-32. The US ROM's value is 0x777AAC2F (see the Android README).
static uint32_t MDCrc32(const uint8_t *bytes, size_t length) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < length; i++) {
    crc ^= bytes[i];
    for (int bit = 0; bit < 8; bit++)
      crc = (crc & 1u) ? ((crc >> 1) ^ 0xEDB88320u) : (crc >> 1);
  }
  return ~crc;
}

static BOOL gInGameForAtExit = NO;

// Die() and SDL failures end in exit(), which iOS treats as a crash: leave a
// marker so the next launch can show the tail of the stderr log.
static void MDAtExitHandler(void) {
  if (gInGameForAtExit) {
    NSString *flag = [MDDocumentsPath() stringByAppendingPathComponent:@"zelda3_crashed"];
    [[NSData data] writeToFile:flag atomically:YES];
  }
}

@implementation MPAppDelegate {
  BOOL _registeredAtExit;
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions {
  if (!_registeredAtExit) {
    _registeredAtExit = YES;
    atexit(MDAtExitHandler);
  }
  BOOL ok = [super application:application didFinishLaunchingWithOptions:launchOptions];
  [self checkRom];
  [self showLauncher];
  return ok;
}

// SDLUIKitDelegate schedules this right after launch; it is the only place
// SDL enters the game from. We defer it until the launcher says go.
- (void)postFinishLaunch {
  if (self.gameRunning || self.romState != MDRomOk)
    return;
  [self startGame];
}

- (void)applicationDidEnterBackground {
  if (self.gameRunning)
    ZeldaWriteSram();
}

#pragma mark - ROM

- (NSString *)romPath {
  return [MDDocumentsPath() stringByAppendingPathComponent:@"zelda3.sfc"];
}

- (void)checkRom {
  NSString *rom = [self romPath];
  NSData *data = [NSData dataWithContentsOfFile:rom options:NSDataReadingMappedIfSafe error:NULL];
  if (data.length == 1049088) {  // 512-byte copier header: strip it, as the Android app does
    data = [data subdataWithRange:NSMakeRange(512, 1048576)];
    [data writeToFile:rom atomically:YES];
  }
  if (data.length == 0) {
    self.romState = MDRomMissing;
  } else if (data.length == 1048576 && MDCrc32(data.bytes, data.length) == 0x777AAC2Fu) {
    self.romState = MDRomOk;
  } else {
    self.romState = MDRomInvalid;
  }
}

- (void)presentRomPicker {
  UIDocumentPickerViewController *picker =
      [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data"]
                                                              inMode:UIDocumentPickerModeImport];
  picker.delegate = self;
  [self.launcherWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  NSURL *url = urls.firstObject;
  if (url == nil)
    return;
  NSData *data = [NSData dataWithContentsOfURL:url options:0 error:NULL];
  if (data.length == 1049088)
    data = [data subdataWithRange:NSMakeRange(512, 1048576)];
  if (data.length == 1048576 && MDCrc32(data.bytes, data.length) == 0x777AAC2Fu) {
    if (![data writeToFile:[self romPath] atomically:YES]) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        [self.launcherViewController showAlertWithTitle:@"Error"
                                                message:@"No se pudo guardar la ROM en el dispositivo."];
      });
    }
  }
  [self checkRom];
  [self refreshLauncher];
}

#pragma mark - Game

- (BOOL)prepareWorkingDirectory:(NSError **)error {
  NSString *docs = MDDocumentsPath();
  if (chdir(docs.fileSystemRepresentation) != 0) {
    if (error) {
      NSString *msg = [NSString stringWithFormat:@"No se pudo usar la carpeta de datos: %s",
                                                 strerror(errno)];
      *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                   code:errno
                               userInfo:@{NSLocalizedDescriptionKey : msg}];
    }
    return NO;
  }
  // The game applies this patch to the ROM itself on first run (LoadAssets).
  NSString *bps = [docs stringByAppendingPathComponent:@"zelda3_assets.bps"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:bps]) {
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"zelda3_assets" ofType:@"bps"];
    if (bundled == nil ||
        ![[NSFileManager defaultManager] copyItemAtPath:bundled toPath:bps error:error]) {
      return NO;
    }
  }
  return YES;
}

- (void)startGame {
  if (self.gameRunning || self.romState != MDRomOk)
    return;
  NSError *error = nil;
  if (![self prepareWorkingDirectory:&error]) {
    [self.launcherViewController showAlertWithTitle:@"Error"
                                            message:error.localizedDescription ?: @"Error desconocido"];
    return;
  }
  self.gameRunning = YES;
  gInGameForAtExit = YES;
  [[NSFileManager defaultManager]
      removeItemAtPath:[MDDocumentsPath() stringByAppendingPathComponent:@"zelda3_crashed"]
                 error:NULL];
  // Keep Die()'s messages; the launcher shows them after an abnormal exit.
  NSString *log = [MDDocumentsPath() stringByAppendingPathComponent:@"zelda3_last_error.log"];
  FILE *reopened = freopen(log.fileSystemRepresentation, "w", stderr);
  (void)reopened;
  setvbuf(stderr, NULL, _IONBF, 0);

  [self hideLauncher];
  if (self.touchControls == nil)
    self.touchControls = [[MPTouchControls alloc] init];
  [self.touchControls show];

  [super postFinishLaunch];  // runs zelda3_main; returns only when the loop exits

  // Clean exit (SDL_QUIT): save and offer the launcher again.
  ZeldaWriteSram();
  gInGameForAtExit = NO;
  self.gameRunning = NO;
  [self.touchControls hide];
  [self showLauncher];
}

#pragma mark - Launcher window

- (nullable MPLauncherViewController *)launcherViewController {
  UIViewController *root = self.launcherWindow.rootViewController;
  return [root isKindOfClass:MPLauncherViewController.class] ? (MPLauncherViewController *)root
                                                             : nil;
}

- (void)showLauncher {
  if (self.launcherWindow == nil) {
    self.launcherWindow = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.launcherWindow.windowLevel = UIWindowLevelNormal + 10;
    MPLauncherViewController *vc = [[MPLauncherViewController alloc] init];
    vc.appDelegate = self;
    self.launcherWindow.rootViewController = vc;
  }
  [self.launcherViewController reloadState];
  [self.launcherWindow makeKeyAndVisible];
}

- (void)hideLauncher {
  self.launcherWindow.hidden = YES;
}

- (void)refreshLauncher {
  [self.launcherViewController reloadState];
}

@end

#pragma mark - Launcher UI

@implementation MPLauncherViewController {
  UILabel *_titleLabel;
  UILabel *_subtitleLabel;
  UILabel *_statusLabel;
  UILabel *_errorLabel;
  UILabel *_helpLabel;
  UILabel *_versionLabel;
  UIButton *_playButton;
  UIButton *_pickButton;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;

  _titleLabel = [self labelWithText:@"ZELDA\nA LINK TO THE PAST"
                               size:24
                               bold:YES
                              color:UIColor.whiteColor];
  _titleLabel.numberOfLines = 2;
  _subtitleLabel = [self labelWithText:@"Puerto iOS del motor zelda3 (código MIT)"
                                 size:13
                                 bold:NO
                                color:[UIColor colorWithWhite:0.6 alpha:1]];
  _statusLabel = [self labelWithText:@"" size:15 bold:YES color:UIColor.systemOrangeColor];
  _statusLabel.numberOfLines = 2;
  _errorLabel = [self labelWithText:@"" size:12 bold:NO color:UIColor.systemRedColor];
  _errorLabel.numberOfLines = 4;
  _errorLabel.hidden = YES;
  _helpLabel = [self labelWithText:@"Controles: cruceta y botones en pantalla; mando Bluetooth también funciona.\n"
                                  @"Importa tu ROM con «Seleccionar ROM…», o copia zelda3.sfc (USA, 1 MiB) "
                                  @"a la carpeta «Zelda 3» desde la app Archivos.\n"
                                  @"Las partidas se guardan al pasar a segundo plano."
                             size:12
                             bold:NO
                            color:[UIColor colorWithWhite:0.55 alpha:1]];
  _helpLabel.numberOfLines = 0;
  _versionLabel = [self labelWithText:@"Uso personal · sin datos de Nintendo incluidos · v1.0"
                                 size:10
                                 bold:NO
                                color:[UIColor colorWithWhite:0.4 alpha:1]];

  _playButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_playButton setTitle:@"▶  JUGAR" forState:UIControlStateNormal];
  _playButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
  [_playButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
  _playButton.backgroundColor = [UIColor colorWithRed:0.35 green:0.78 blue:0.35 alpha:1];
  _playButton.layer.cornerRadius = 12;
  [_playButton addTarget:self action:@selector(onPlay) forControlEvents:UIControlEventTouchUpInside];

  _pickButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [_pickButton setTitle:@"Seleccionar ROM…" forState:UIControlStateNormal];
  _pickButton.titleLabel.font = [UIFont systemFontOfSize:17];
  [_pickButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  _pickButton.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
  _pickButton.layer.cornerRadius = 10;
  _pickButton.layer.borderWidth = 1;
  _pickButton.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
  [_pickButton addTarget:self action:@selector(onPick) forControlEvents:UIControlEventTouchUpInside];

  for (UIView *v in @[
         _titleLabel, _subtitleLabel, _statusLabel, _errorLabel, _playButton, _pickButton,
         _helpLabel, _versionLabel
       ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:v];
  }

  UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [_titleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_titleLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
    [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

    [_subtitleLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
    [_subtitleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
    [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

    [_statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_statusLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:14],
    [_statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
    [_statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

    [_errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_errorLabel.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:6],
    [_errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
    [_errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

    [_playButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_playButton.topAnchor constraintEqualToAnchor:_errorLabel.bottomAnchor constant:18],
    [_playButton.widthAnchor constraintEqualToConstant:280],
    [_playButton.heightAnchor constraintEqualToConstant:54],

    [_pickButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_pickButton.topAnchor constraintEqualToAnchor:_playButton.bottomAnchor constant:10],
    [_pickButton.widthAnchor constraintEqualToConstant:280],
    [_pickButton.heightAnchor constraintEqualToConstant:42],

    [_helpLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_helpLabel.topAnchor constraintEqualToAnchor:_pickButton.bottomAnchor constant:16],
    [_helpLabel.widthAnchor constraintLessThanOrEqualToConstant:560],
    [_helpLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:24],
    [_helpLabel.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-24],

    [_versionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    [_versionLabel.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
  ]];
}

- (UILabel *)labelWithText:(NSString *)text
                      size:(CGFloat)size
                      bold:(BOOL)bold
                     color:(UIColor *)color {
  UILabel *label = [[UILabel alloc] init];
  label.text = text;
  label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
  label.textColor = color;
  label.textAlignment = NSTextAlignmentCenter;
  return label;
}

- (void)reloadState {
  MPAppDelegate *app = self.appDelegate;
  switch (app.romState) {
    case MDRomOk:
      _statusLabel.text = @"ROM lista: A Link to the Past (USA)";
      _statusLabel.textColor = UIColor.systemGreenColor;
      break;
    case MDRomInvalid:
      _statusLabel.text = @"ROM no válida: hace falta la versión USA (1 MiB)";
      _statusLabel.textColor = UIColor.systemOrangeColor;
      break;
    case MDRomMissing:
    default:
      _statusLabel.text = @"Sin ROM: importa tu copia para jugar";
      _statusLabel.textColor = UIColor.systemOrangeColor;
      break;
  }
  BOOL ready = app.romState == MDRomOk;
  _playButton.enabled = ready;
  _playButton.alpha = ready ? 1.0 : 0.45;

  NSString *flag = [MDDocumentsPath() stringByAppendingPathComponent:@"zelda3_crashed"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:flag]) {
    NSString *logPath = [MDDocumentsPath() stringByAppendingPathComponent:@"zelda3_last_error.log"];
    NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
    NSString *tail = @"";
    if (log.length > 0)
      tail = log.length > 300 ? [log substringFromIndex:log.length - 300] : log;
    _errorLabel.text = [@"La última sesión terminó con error.\n" stringByAppendingString:tail];
    _errorLabel.hidden = NO;
  } else {
    _errorLabel.hidden = YES;
  }
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
  if (self.presentedViewController != nil)
    return;
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)onPlay {
  [self.appDelegate startGame];
}

- (void)onPick {
  [self.appDelegate presentRomPicker];
}

- (BOOL)prefersStatusBarHidden {
  return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

@end

NS_ASSUME_NONNULL_END
