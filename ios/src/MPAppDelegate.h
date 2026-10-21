#import <UIKit/UIKit.h>

// SDLUIKitDelegate runs SDL's UIKit integration and starts the game from
// -postFinishLaunch; MPAppDelegate gates that behind its launcher.
#import "SDL_uikitappdelegate.h"

NS_ASSUME_NONNULL_BEGIN

/// Application delegate of the iOS port: a subclass of SDL's SDLUIKitDelegate
/// (SDL documents the subclassing via a category on +getAppDelegateClassName)
/// that shows a launcher with ROM import and gates the call into the game.
@interface MPAppDelegate : SDLUIKitDelegate
@end

NS_ASSUME_NONNULL_END
