// iOS entry point for the zelda3 port.
//
// SDL's UIKit run loop (SDL_UIKitRunApp + SDLUIKitDelegate) starts the game
// by calling the function passed here. It would normally be SDL_main, but
// main.c force-undefines the main macro, so we build it as zelda3_main
// (patches/zelda3/0011-ios-entry-point.patch) and hand that over instead.
//
// When the call actually happens is decided by MPAppDelegate (the delegate
// subclass): only once the launcher has a valid ROM in Documents, the game's
// working directory, holding zelda3.ini, zelda3_assets.bps and saves/.
#include <SDL.h>

int zelda3_main(int argc, char **argv);  // src/main.c via patch 0011

#undef main
int main(int argc, char *argv[]) {
  return SDL_UIKitRunApp(argc, argv, zelda3_main);
}
