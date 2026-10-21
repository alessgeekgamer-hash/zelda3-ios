#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Application delegate of the iOS port: a subclass of SDL's SDLUIKitDelegate
/// (SDL documents the subclassing via a category on +getAppDelegateClassName)
/// that shows a launcher with ROM import and gates the call into the game.
@interface MPAppDelegate : UIResponder <UIApplicationDelegate>
@end

NS_ASSUME_NONNULL_END
