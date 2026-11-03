#!/usr/bin/env python3
"""Copies winit 0.30.13 from Cargo's registry into a Horizon checkout's third_party/winit and
patches its iOS backend for Amadora:

- EventLoop::run joins an app that is already running (Amadora calls the game from a button)
  instead of calling UIApplicationMain, then keeps the main run loop turning;
- the game's window joins the app's window scene, or a scene-based app never shows it;
- set_cursor_grab and set_cursor_position succeed, so the game can hold the pointer;
- the input bridge (winit_amadora.rs) is public as winit::platform::ios::amadora.

usage: patch_winit.py WINIT_SRC_DIR HORIZON_DIR
"""
import shutil
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
src, horizon = Path(sys.argv[1]), Path(sys.argv[2])
dest = horizon / "third_party" / "winit"
if dest.exists():
    shutil.rmtree(dest)
shutil.copytree(src, dest)
ios = dest / "src" / "platform_impl" / "ios"


def sub(path, old, new):
    text = path.read_text(encoding="utf-8")
    if text.count(old) != 1:
        sys.exit(f"patch_winit: {path.name}: expected one match of {old[:70]!r}, found {text.count(old)}")
    path.write_text(text.replace(old, new), encoding="utf-8")


shutil.copy(here / "winit_amadora.rs", ios / "amadora.rs")
sub(ios / "mod.rs", "mod app_state;\n", "mod app_state;\npub(crate) mod amadora;\n")

sub(dest / "src" / "platform" / "ios.rs", "\nuse std::os::raw::c_void;\n", """
/// Amadora: input from the host app's touch controls, keyboard and mouse.
pub mod amadora {
    pub use crate::platform_impl::amadora::{
        cursor, cursor_grabbed, has_window, key, mouse_button, mouse_motion, scroll, text,
    };
}

use std::os::raw::c_void;
""")

# run: join the running app.
sub(ios / "event_loop.rs", """        let application: Option<Retained<UIApplication>> =
            unsafe { msg_send_id![UIApplication::class(), sharedApplication] };
        assert!(
            application.is_none(),""", """        let application: Option<Retained<UIApplication>> =
            unsafe { msg_send_id![UIApplication::class(), sharedApplication] };
        if application.is_some() {
            // Amadora: started from inside a running app. Launch as UIApplicationMain would
            // have, resume (the app is already active), then keep the main run loop turning:
            // this call never returns, as on every other path.
            let handler = map_user_event(handler, self.receiver);
            let handler = unsafe {
                std::mem::transmute::<
                    Box<dyn FnMut(Event<HandlePendingUserEvents>, &RootActiveEventLoop)>,
                    Box<dyn FnMut(Event<HandlePendingUserEvents>, &RootActiveEventLoop)>,
                >(Box::new(handler))
            };
            let handler = EventLoopHandler { handler, event_loop: self.window_target };
            app_state::will_launch(self.mtm, handler);
            app_state::did_finish_launching(self.mtm);
            app_state::handle_nonuser_event(self.mtm, EventWrapper::StaticEvent(Event::Resumed));
            loop {
                unsafe { core_foundation::runloop::CFRunLoopRun() };
            }
        }
        assert!(
            application.is_none(),""")

# The window joins the app's scene, and becomes the one that gets input.
sub(ios / "window.rs", """        this.setRootViewController(Some(view_controller));
""", """        this.setRootViewController(Some(view_controller));

        // Amadora: in a scene-based app a window shows only once it joins a scene.
        unsafe {
            let app: *mut objc2::runtime::AnyObject =
                objc2::msg_send![objc2::class!(UIApplication), sharedApplication];
            if !app.is_null() {
                let key: *mut objc2::runtime::AnyObject = objc2::msg_send![app, keyWindow];
                if !key.is_null() {
                    let scene: *mut objc2::runtime::AnyObject = objc2::msg_send![key, windowScene];
                    if !scene.is_null() {
                        let _: () = objc2::msg_send![&*this, setWindowScene: scene];
                    }
                }
            }
        }
        super::amadora::set_window(this.id().into());
""")
sub(ios / "window.rs", """    pub fn set_cursor_position(&self, _position: Position) -> Result<(), ExternalError> {
        Err(ExternalError::NotSupported(NotSupportedError::new()))
    }

    pub fn set_cursor_grab(&self, _: CursorGrabMode) -> Result<(), ExternalError> {
        Err(ExternalError::NotSupported(NotSupportedError::new()))
    }""", """    pub fn set_cursor_position(&self, _position: Position) -> Result<(), ExternalError> {
        // Amadora: there is no pointer to move; the touch controls keep their own.
        Ok(())
    }

    pub fn set_cursor_grab(&self, mode: CursorGrabMode) -> Result<(), ExternalError> {
        // Amadora: the touch controls turn the camera while the game holds the pointer.
        super::amadora::set_grabbed(!matches!(mode, CursorGrabMode::None));
        Ok(())
    }""")
# The game asks for a desktop-sized window; on a phone it fills the screen.
sub(ios / "window.rs", """        let frame = match window_attributes.inner_size {""", """        // Amadora: the game fills the screen whatever size it asks for.
        let frame = match Option::<crate::dpi::Size>::None {""")
print(f"patch_winit: patched {dest}")
