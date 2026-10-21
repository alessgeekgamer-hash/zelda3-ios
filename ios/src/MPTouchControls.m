// On-screen controls for the iOS port.
//
// The overlay is its own UIWindow above SDL's (windowLevel), transparent
// except for the buttons. Its root view returns nil from hitTest outside the
// control areas, so touches there reach SDL's window untouched. Button
// presses are injected as SDL_CONTROLLERBUTTONDOWN/UP events — exactly what
// a Bluetooth controller would send — and main.c maps them by position
// (SDL B = SNES A, SDL A = SNES B, X/Y as on the pad), so the on-screen
// letters match the original game.
//
// The main thread runs the game loop, but SDL pumps the UIKit run loop
// while it polls (SDL_iPhoneSetEventPump), so touches arrive normally.
#import "MPTouchControls.h"

#include <SDL.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, MDPlacement) {
  MDFace,           // bottom-right diamond; laid out around a center point
  MDTopleft,        // L
  MDTopright,       // R
  MDTopcenterLeft,  // Select
  MDTopcenterRight, // Start
};

@interface MPControl : NSObject
@property (nonatomic, assign) int sdlButton;
@property (nonatomic, copy) NSString *caption;
@property (nonatomic, assign) MDPlacement placement;
@property (nonatomic, assign) CGPoint faceOffset;
@property (nonatomic, assign) CGRect rect;
@property (nonatomic, strong) UIView *view;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, assign) BOOL pressed;
@end

@implementation MPControl
@end

@class MPTouchControls;

@interface MPOverlayView : UIView
@property (nonatomic, weak, nullable) MPTouchControls *owner;
@end

@interface MPTouchControls ()
@property (nonatomic, strong, nullable) UIWindow *window;
@property (nonatomic, strong, nullable) MPOverlayView *overlay;
@property (nonatomic, strong, nullable) UIView *dpadView;
@property (nonatomic, strong) NSMutableArray<MPControl *> *controls;
/// NSValue of the UITouch (pointer identity) -> the MPControl it presses,
/// or NSNull for the touch currently owning the d-pad.
@property (nonatomic, strong) NSMutableDictionary<NSValue *, id> *touchOwners;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *heldButtons;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *heldDpad;
@property (nonatomic, assign) CGRect dpadZone;
- (void)handleTouchesBegan:(NSSet<UITouch *> *)touches;
- (void)handleTouchesMoved:(NSSet<UITouch *> *)touches;
- (void)handleTouchesEnded:(NSSet<UITouch *> *)touches;
- (BOOL)pointInsideControl:(CGPoint)point;
- (void)layoutControlsInBounds:(CGRect)bounds safeInsets:(UIEdgeInsets)insets;
@end

#pragma mark - Pass-through root view

@implementation MPOverlayView

// Everything the overlay does not claim (the empty screen) returns nil, and
// UIKit routes the touch to the window below — SDL's.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  UIView *hit = [super hitTest:point withEvent:event];
  if (hit == nil)
    return nil;
  if (hit == self)
    return [self.owner pointInsideControl:point] ? self : nil;
  return hit;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [self.owner layoutControlsInBounds:self.bounds safeInsets:self.safeAreaInsets];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self.owner handleTouchesBegan:touches];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self.owner handleTouchesMoved:touches];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self.owner handleTouchesEnded:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  [self.owner handleTouchesEnded:touches];
}

@end

#pragma mark - Controls

@implementation MPTouchControls {
  UILabel *_dpadCaption;
}

- (instancetype)init {
  if (!(self = [super init]))
    return nil;
  _controls = [NSMutableArray array];
  _touchOwners = [NSMutableDictionary dictionary];
  _heldButtons = [NSMutableSet set];
  _heldDpad = [NSMutableSet set];
  return self;
}

static void MDSendButton(int sdlButton, BOOL down) {
  // After SDL_Quit there is no event queue to push into; dropping the event
  // (rather than touching a dead subsystem) is what hide-on-exit wants.
  if (!SDL_WasInit(SDL_INIT_EVENTS))
    return;
  SDL_Event event;
  SDL_zero(event);
  event.type = down ? SDL_CONTROLLERBUTTONDOWN : SDL_CONTROLLERBUTTONUP;
  event.cbutton.which = 0;
  event.cbutton.button = (Uint8)sdlButton;
  event.cbutton.timestamp = (Uint32)SDL_GetTicks();
  SDL_PushEvent(&event);
}

- (void)show {
  [self buildIfNeeded];
  self.window.hidden = NO;  // deliberately not makeKeyAndVisible: SDL owns the key window
}

- (void)hide {
  [self releaseAllInputs];
  self.window.hidden = YES;
}

- (void)buildIfNeeded {
  if (self.window != nil)
    return;
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.windowLevel = UIWindowLevelNormal + 5;

  MPOverlayView *overlay = [[MPOverlayView alloc] initWithFrame:self.window.bounds];
  overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  overlay.backgroundColor = UIColor.clearColor;
  overlay.multipleTouchEnabled = YES;  // run + attack at the same time
  overlay.owner = self;
  self.overlay = overlay;

  UIViewController *root = [[UIViewController alloc] init];
  root.view = overlay;
  self.window.rootViewController = root;

  // The d-pad zone (a plain view for visuals; the hit test uses _dpadZone).
  UIView *dpad = [[UIView alloc] init];
  dpad.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
  dpad.userInteractionEnabled = NO;
  UILabel *plus = [[UILabel alloc] init];
  plus.text = @"+";
  plus.font = [UIFont boldSystemFontOfSize:44];
  plus.textColor = [UIColor colorWithWhite:1 alpha:0.55];
  plus.textAlignment = NSTextAlignmentCenter;
  plus.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [dpad addSubview:plus];
  [overlay addSubview:dpad];
  self.dpadView = dpad;
  _dpadCaption = plus;

  // Face buttons by SNES position; sdlButton holds the SDL/Xbox-position
  // equivalent (SDL B is on the right, where SNES A is, and so on).
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_B
                       caption:@"A"
                     placement:MDFace
                        offset:CGPointMake(58, 0)
                          round:YES];
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_A
                       caption:@"B"
                     placement:MDFace
                        offset:CGPointMake(0, 58)
                          round:YES];
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_X
                       caption:@"X"
                     placement:MDFace
                        offset:CGPointMake(0, -58)
                          round:YES];
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_Y
                       caption:@"Y"
                     placement:MDFace
                        offset:CGPointMake(-58, 0)
                          round:YES];

  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_LEFTSHOULDER
                       caption:@"L"
                     placement:MDTopleft
                        offset:CGPointZero
                          round:NO];
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_RIGHTSHOULDER
                       caption:@"R"
                     placement:MDTopright
                        offset:CGPointZero
                          round:NO];
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_BACK
                       caption:@"SELECT"
                     placement:MDTopcenterLeft
                        offset:CGPointZero
                          round:NO];
  [self addButtonWithSdlButton:SDL_CONTROLLER_BUTTON_START
                       caption:@"START"
                     placement:MDTopcenterRight
                        offset:CGPointZero
                          round:NO];
}

- (void)addButtonWithSdlButton:(int)sdlButton
                       caption:(NSString *)caption
                     placement:(MDPlacement)placement
                        offset:(CGPoint)offset
                          round:(BOOL)round {
  MPControl *control = [[MPControl alloc] init];
  control.sdlButton = sdlButton;
  control.caption = caption;
  control.placement = placement;
  control.faceOffset = offset;

  UIView *view = [[UIView alloc] init];
  view.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
  view.layer.borderWidth = 1.5;
  view.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
  view.userInteractionEnabled = NO;  // touches are centralized in the overlay

  UILabel *label = [[UILabel alloc] init];
  label.text = caption;
  label.font = [UIFont boldSystemFontOfSize:caption.length > 1 ? 12 : 22];
  label.textColor = UIColor.whiteColor;
  label.textAlignment = NSTextAlignmentCenter;
  label.frame = view.bounds;
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [view addSubview:label];

  [self.overlay addSubview:view];
  control.view = view;
  control.label = label;
  [self.controls addObject:control];
}

- (void)layoutControlsInBounds:(CGRect)bounds safeInsets:(UIEdgeInsets)safe {
  if (self.overlay == nil || self.controls.count == 0)
    return;
  CGFloat w = bounds.size.width, h = bounds.size.height;

  CGFloat dpadSize = 156;
  self.dpadZone = CGRectMake(safe.left + 12, h - safe.bottom - 12 - dpadSize, dpadSize, dpadSize);
  self.dpadView.frame = self.dpadZone;
  self.dpadView.layer.cornerRadius = dpadSize / 2;

  CGPoint faceCenter = CGPointMake(w - safe.right - 100, h - safe.bottom - 100);
  CGFloat topY = safe.top + 10;
  CGFloat midX = w / 2;

  for (MPControl *control in self.controls) {
    CGRect rect;
    switch (control.placement) {
      case MDFace:
        rect = CGRectMake(faceCenter.x + control.faceOffset.x - 30,
                          faceCenter.y + control.faceOffset.y - 30, 60, 60);
        break;
      case MDTopleft:
        rect = CGRectMake(safe.left + 10, topY, 104, 42);
        break;
      case MDTopright:
        rect = CGRectMake(w - safe.right - 10 - 104, topY, 104, 42);
        break;
      case MDTopcenterLeft:
        rect = CGRectMake(midX - 96, topY, 88, 38);
        break;
      case MDTopcenterRight:
      default:
        rect = CGRectMake(midX + 8, topY, 88, 38);
        break;
    }
    control.rect = rect;
    control.view.frame = rect;
    control.view.layer.cornerRadius =
        (control.placement == MDFace) ? CGRectGetWidth(rect) / 2 : 12;
  }
}

#pragma mark - Touch ownership

static NSValue *MDKeyForTouch(UITouch *touch) {
  return [NSValue valueWithNonretainedObject:touch];
}

- (nullable MPControl *)controlAtPoint:(CGPoint)point {
  for (MPControl *control in self.controls) {
    if (CGRectContainsPoint(control.rect, point))
      return control;
  }
  return nil;
}

- (BOOL)pointInsideControl:(CGPoint)point {
  if (CGRectContainsPoint(self.dpadZone, point))
    return YES;
  return [self controlAtPoint:point] != nil;
}

- (BOOL)hasDpadOwner {
  for (id owner in self.touchOwners.allValues) {
    if (owner == [NSNull null])
      return YES;
  }
  return NO;
}

- (void)handleTouchesBegan:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    CGPoint point = [touch locationInView:self.overlay];
    if (CGRectContainsPoint(self.dpadZone, point)) {
      if (![self hasDpadOwner]) {
        self.touchOwners[MDKeyForTouch(touch)] = [NSNull null];
        [self updateDpadWithPoint:point];
      }
      continue;
    }
    MPControl *control = [self controlAtPoint:point];
    if (control != nil) {
      self.touchOwners[MDKeyForTouch(touch)] = control;
      [self pressControl:control];
    }
  }
}

- (void)handleTouchesMoved:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    id owner = self.touchOwners[MDKeyForTouch(touch)];
    if (owner == nil)
      continue;
    CGPoint point = [touch locationInView:self.overlay];
    if (owner == [NSNull null]) {
      [self updateDpadWithPoint:point];
      continue;
    }
    MPControl *control = (MPControl *)owner;
    MPControl *now = [self controlAtPoint:point];
    if (now != nil && now != control) {  // slid onto another button
      [self releaseControl:control];
      self.touchOwners[MDKeyForTouch(touch)] = now;
      [self pressControl:now];
    } else if (now == control) {
      [self pressControl:control];  // idempotent
    } else {  // wandered off: release, but keep the owner so a slide back re-presses
      [self releaseControl:control];
    }
  }
}

- (void)handleTouchesEnded:(NSSet<UITouch *> *)touches {
  for (UITouch *touch in touches) {
    NSValue *key = MDKeyForTouch(touch);
    id owner = self.touchOwners[key];
    if (owner == nil)
      continue;
    [self.touchOwners removeObjectForKey:key];
    if (owner == [NSNull null]) {
      [self applyDpadSet:NSSet.new];
    } else {
      [self releaseControl:(MPControl *)owner];
    }
  }
}

#pragma mark - Press state

- (void)pressControl:(MPControl *)control {
  NSNumber *button = @(control.sdlButton);
  if (![self.heldButtons containsObject:button]) {
    [self.heldButtons addObject:button];
    MDSendButton(control.sdlButton, YES);
  }
  if (!control.pressed) {
    control.pressed = YES;
    control.view.backgroundColor = [UIColor colorWithRed:1 green:0.92 blue:0.35 alpha:0.45];
  }
}

- (void)releaseControl:(MPControl *)control {
  NSNumber *button = @(control.sdlButton);
  if ([self.heldButtons containsObject:button]) {
    [self.heldButtons removeObject:button];
    MDSendButton(control.sdlButton, NO);
  }
  if (control.pressed) {
    control.pressed = NO;
    control.view.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
  }
}

- (void)updateDpadWithPoint:(CGPoint)point {
  CGRect zone = self.dpadZone;
  CGFloat dx = point.x - CGRectGetMidX(zone);
  CGFloat dy = point.y - CGRectGetMidY(zone);
  CGFloat dead = zone.size.width * 0.16;
  NSMutableSet<NSNumber *> *want = NSMutableSet.new;
  if (dx > dead)
    [want addObject:@(SDL_CONTROLLER_BUTTON_DPAD_RIGHT)];
  else if (dx < -dead)
    [want addObject:@(SDL_CONTROLLER_BUTTON_DPAD_LEFT)];
  if (dy > dead)
    [want addObject:@(SDL_CONTROLLER_BUTTON_DPAD_DOWN)];
  else if (dy < -dead)
    [want addObject:@(SDL_CONTROLLER_BUTTON_DPAD_UP)];
  [self applyDpadSet:want];
}

- (void)applyDpadSet:(NSSet<NSNumber *> *)want {
  for (NSNumber *button in want) {
    if (![self.heldDpad containsObject:button]) {
      [self.heldDpad addObject:button];
      MDSendButton(button.intValue, YES);
    }
  }
  for (NSNumber *button in self.heldDpad.copy) {
    if (![want containsObject:button]) {
      [self.heldDpad removeObject:button];
      MDSendButton(button.intValue, NO);
    }
  }
}

- (void)releaseAllInputs {
  [self.touchOwners removeAllObjects];
  for (MPControl *control in self.controls) {
    if (control.pressed)
      [self releaseControl:control];
  }
  [self applyDpadSet:NSSet.new];
}

@end

NS_ASSUME_NONNULL_END
