//! Amadora: the game's window inside an iOS app that is already running, with input
//! from the app's touch controls, hardware keyboard and mouse. winit has neither a
//! keyboard nor a mouse on iOS, so the app sends them here as USB HID key usages
//! (what UIKit's UIKey and GameController's GCKeyboard report) and pointer moves.
//! Copied into winit 0.30.13 by tools/horizon/patch_winit.py.

use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

use objc2_foundation::MainThreadMarker;

use super::app_state::{self, EventWrapper};
use super::window::WindowId;
use super::DEVICE_ID;
use crate::dpi::PhysicalPosition;
use crate::event::{
    DeviceEvent, ElementState, Event, Ime, KeyEvent, Modifiers, MouseButton, MouseScrollDelta,
    TouchPhase, WindowEvent,
};
use crate::keyboard::{Key, KeyCode, KeyLocation, ModifiersState, NamedKey, PhysicalKey, SmolStr};
use crate::window::WindowId as RootWindowId;

/// The last window the game created, which gets the input.
static WINDOW: AtomicU64 = AtomicU64::new(0);
static HAS_WINDOW: AtomicBool = AtomicBool::new(false);
/// Whether the game holds the pointer (`set_cursor_grab`): touches look around instead of pointing.
static GRABBED: AtomicBool = AtomicBool::new(false);
/// The modifier keys held, as `ModifiersState` bits.
static MODIFIERS: AtomicU32 = AtomicU32::new(0);

pub(crate) fn set_window(id: u64) {
    WINDOW.store(id, Ordering::Relaxed);
    HAS_WINDOW.store(true, Ordering::Relaxed);
}

pub(crate) fn set_grabbed(grabbed: bool) {
    GRABBED.store(grabbed, Ordering::Relaxed);
}

/// Whether the game holds the pointer (it is playing, not in a menu).
pub fn cursor_grabbed() -> bool {
    GRABBED.load(Ordering::Relaxed)
}

/// Whether the game has opened its window yet.
pub fn has_window() -> bool {
    HAS_WINDOW.load(Ordering::Relaxed)
}

fn send_window(event: WindowEvent) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    if !has_window() {
        return;
    }
    let window_id = RootWindowId(WindowId::from(WINDOW.load(Ordering::Relaxed)));
    app_state::handle_nonuser_event(
        mtm,
        EventWrapper::StaticEvent(Event::WindowEvent { window_id, event }),
    );
}

fn send_device(event: DeviceEvent) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    if !has_window() {
        return;
    }
    app_state::handle_nonuser_event(
        mtm,
        EventWrapper::StaticEvent(Event::DeviceEvent { device_id: DEVICE_ID, event }),
    );
}

/// The key on a US layout with this HID usage (UIKeyboardHIDUsage), with what it writes
/// without and with Shift.
fn hid_key(hid: u32) -> Option<(KeyCode, Key, Option<(char, char)>)> {
    use KeyCode as C;
    const LETTERS: [KeyCode; 26] = [
        C::KeyA, C::KeyB, C::KeyC, C::KeyD, C::KeyE, C::KeyF, C::KeyG, C::KeyH, C::KeyI,
        C::KeyJ, C::KeyK, C::KeyL, C::KeyM, C::KeyN, C::KeyO, C::KeyP, C::KeyQ, C::KeyR,
        C::KeyS, C::KeyT, C::KeyU, C::KeyV, C::KeyW, C::KeyX, C::KeyY, C::KeyZ,
    ];
    const DIGITS: [(KeyCode, char, char); 10] = [
        (C::Digit1, '1', '!'),
        (C::Digit2, '2', '@'),
        (C::Digit3, '3', '#'),
        (C::Digit4, '4', '$'),
        (C::Digit5, '5', '%'),
        (C::Digit6, '6', '^'),
        (C::Digit7, '7', '&'),
        (C::Digit8, '8', '*'),
        (C::Digit9, '9', '('),
        (C::Digit0, '0', ')'),
    ];
    const FKEYS: [(KeyCode, NamedKey); 12] = [
        (C::F1, NamedKey::F1),
        (C::F2, NamedKey::F2),
        (C::F3, NamedKey::F3),
        (C::F4, NamedKey::F4),
        (C::F5, NamedKey::F5),
        (C::F6, NamedKey::F6),
        (C::F7, NamedKey::F7),
        (C::F8, NamedKey::F8),
        (C::F9, NamedKey::F9),
        (C::F10, NamedKey::F10),
        (C::F11, NamedKey::F11),
        (C::F12, NamedKey::F12),
    ];
    let printable = |code, plain: char, shifted: char| {
        Some((code, Key::Character(SmolStr::new(plain.to_string())), Some((plain, shifted))))
    };
    let named = |code, key| Some((code, Key::Named(key), None));
    match hid {
        4..=29 => {
            let c = (b'a' + (hid - 4) as u8) as char;
            printable(LETTERS[(hid - 4) as usize], c, c.to_ascii_uppercase())
        },
        30..=39 => {
            let (code, plain, shifted) = DIGITS[(hid - 30) as usize];
            printable(code, plain, shifted)
        },
        40 => named(C::Enter, NamedKey::Enter),
        41 => named(C::Escape, NamedKey::Escape),
        42 => named(C::Backspace, NamedKey::Backspace),
        43 => named(C::Tab, NamedKey::Tab),
        44 => Some((C::Space, Key::Named(NamedKey::Space), Some((' ', ' ')))),
        45 => printable(C::Minus, '-', '_'),
        46 => printable(C::Equal, '=', '+'),
        47 => printable(C::BracketLeft, '[', '{'),
        48 => printable(C::BracketRight, ']', '}'),
        49 => printable(C::Backslash, '\\', '|'),
        51 => printable(C::Semicolon, ';', ':'),
        52 => printable(C::Quote, '\'', '"'),
        53 => printable(C::Backquote, '`', '~'),
        54 => printable(C::Comma, ',', '<'),
        55 => printable(C::Period, '.', '>'),
        56 => printable(C::Slash, '/', '?'),
        57 => named(C::CapsLock, NamedKey::CapsLock),
        58..=69 => {
            let (code, key) = FKEYS[(hid - 58) as usize];
            named(code, key)
        },
        70 => named(C::PrintScreen, NamedKey::PrintScreen),
        71 => named(C::ScrollLock, NamedKey::ScrollLock),
        72 => named(C::Pause, NamedKey::Pause),
        73 => named(C::Insert, NamedKey::Insert),
        74 => named(C::Home, NamedKey::Home),
        75 => named(C::PageUp, NamedKey::PageUp),
        76 => named(C::Delete, NamedKey::Delete),
        77 => named(C::End, NamedKey::End),
        78 => named(C::PageDown, NamedKey::PageDown),
        79 => named(C::ArrowRight, NamedKey::ArrowRight),
        80 => named(C::ArrowLeft, NamedKey::ArrowLeft),
        81 => named(C::ArrowDown, NamedKey::ArrowDown),
        82 => named(C::ArrowUp, NamedKey::ArrowUp),
        224 => named(C::ControlLeft, NamedKey::Control),
        225 => named(C::ShiftLeft, NamedKey::Shift),
        226 => named(C::AltLeft, NamedKey::Alt),
        227 => named(C::SuperLeft, NamedKey::Super),
        228 => named(C::ControlRight, NamedKey::Control),
        229 => named(C::ShiftRight, NamedKey::Shift),
        230 => named(C::AltRight, NamedKey::Alt),
        231 => named(C::SuperRight, NamedKey::Super),
        _ => None,
    }
}

/// A key pressed or released, by its USB HID usage (UIKeyboardHIDUsage).
pub fn key(hid: u32, pressed: bool) {
    let Some((code, logical, chars)) = hid_key(hid) else {
        return;
    };
    let location = match hid {
        224..=227 => KeyLocation::Left,
        228..=231 => KeyLocation::Right,
        _ => KeyLocation::Standard,
    };
    let modifier = match hid {
        224 | 228 => Some(ModifiersState::CONTROL),
        225 | 229 => Some(ModifiersState::SHIFT),
        226 | 230 => Some(ModifiersState::ALT),
        227 | 231 => Some(ModifiersState::SUPER),
        _ => None,
    };
    let mut held = ModifiersState::from_bits_truncate(MODIFIERS.load(Ordering::Relaxed));
    if let Some(m) = modifier {
        held.set(m, pressed);
        MODIFIERS.store(held.bits(), Ordering::Relaxed);
    }
    let shift = held.shift_key();
    let (logical, text) = match (chars, &logical) {
        (Some((plain, shifted)), Key::Character(_)) => {
            let c = if shift { shifted } else { plain };
            (Key::Character(SmolStr::new(c.to_string())), Some(c))
        },
        (Some((c, _)), _) => (logical, Some(c)),
        (None, _) => (logical, None),
    };
    let writes = pressed && !held.control_key() && !held.super_key();
    let event = KeyEvent {
        physical_key: PhysicalKey::Code(code),
        logical_key: logical,
        text: text.filter(|_| writes).map(|c| SmolStr::new(c.to_string())),
        location,
        state: if pressed { ElementState::Pressed } else { ElementState::Released },
        repeat: false,
        platform_specific: super::KeyEventExtra {},
    };
    if modifier.is_some() {
        send_window(WindowEvent::ModifiersChanged(Modifiers::from(held)));
    }
    send_window(WindowEvent::KeyboardInput {
        device_id: DEVICE_ID,
        event,
        is_synthetic: false,
    });
}

/// Text typed on the on-screen keyboard.
pub fn text(text: &str) {
    if !text.is_empty() {
        send_window(WindowEvent::Ime(Ime::Commit(text.to_owned())));
    }
}

/// A mouse button: 0 left, 1 right, 2 middle, 3 back, 4 forward.
pub fn mouse_button(button: u32, pressed: bool) {
    let button = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        3 => MouseButton::Back,
        4 => MouseButton::Forward,
        n => MouseButton::Other(n as u16),
    };
    send_window(WindowEvent::MouseInput {
        device_id: DEVICE_ID,
        state: if pressed { ElementState::Pressed } else { ElementState::Released },
        button,
    });
}

/// The pointer at (`x`, `y`) in the window, in physical pixels.
pub fn cursor(x: f64, y: f64) {
    send_window(WindowEvent::CursorMoved {
        device_id: DEVICE_ID,
        position: PhysicalPosition::new(x, y),
    });
}

/// The mouse moved by (`dx`, `dy`) counts: turns the camera while the pointer is grabbed.
pub fn mouse_motion(dx: f64, dy: f64) {
    send_device(DeviceEvent::MouseMotion { delta: (dx, dy) });
}

/// The wheel turned by (`dx`, `dy`) lines.
pub fn scroll(dx: f64, dy: f64) {
    send_window(WindowEvent::MouseWheel {
        device_id: DEVICE_ID,
        delta: MouseScrollDelta::LineDelta(dx as f32, dy as f32),
        phase: TouchPhase::Moved,
    });
}
