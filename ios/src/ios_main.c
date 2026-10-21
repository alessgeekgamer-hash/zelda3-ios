// iOS entry point for the zelda3 port.
//
// SDL's UIKit run loop (SDL_UIKitRunApp + SDLUIKitDelegate) starts the game by
// calling the function passed here. main.c force-undefines the main macro, so
// we build it as zelda3_main (patches/zelda3/0011-ios-entry-point.patch) and
// hand that over instead.
//
// The first game frame logs the audio driver SDL actually opened and the
// iOS audio session state to the log file (stderr), to diagnose playback
// that comes out silent on device.
#include <SDL.h>
#include <stdbool.h>

int zelda3_main(int argc, char **argv);      // src/main.c via patch 0011
void ZeldaSetFrameHook(void (*hook)(void));  // patches/zelda3/0002-frame-hook.patch
void MDAudioDiagnosticsLog(void);             // MPAppDelegate.m

static void IosFrameHook(void) {
  static bool logged;
  if (logged)
    return;
  logged = true;
  MDAudioDiagnosticsLog();
}

#undef main
int main(int argc, char *argv[]) {
  ZeldaSetFrameHook(IosFrameHook);
  return SDL_UIKitRunApp(argc, argv, zelda3_main);
}
