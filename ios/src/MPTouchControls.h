#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// On-screen controls overlaid on the game window: d-pad, A/B/X/Y (SNES
/// positions), L/R, Start and Select. Touches outside the controls fall
/// through to SDL's window, and each button injects an SDL controller
/// event, so the game sees an ordinary gamepad.
@interface MPTouchControls : NSObject

/// Shows the overlay window (created on first use).
- (void)show;

/// Releases everything it holds and hides the overlay.
- (void)hide;

@end

NS_ASSUME_NONNULL_END
