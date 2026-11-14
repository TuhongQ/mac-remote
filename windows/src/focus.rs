//! Finds editable Windows controls after a tap without blocking remote input.

use std::sync::{mpsc, OnceLock};
use std::thread;
use std::time::Duration;

use windows::Win32::Foundation::POINT;
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationValuePattern, UIA_EditControlTypeId,
    UIA_ValuePatternId,
};

type Check = (i32, i32, Box<dyn FnOnce(bool) + Send>);
static FOCUS_CHECKS: OnceLock<mpsc::SyncSender<Check>> = OnceLock::new();

pub fn check(x: i32, y: i32, reply: impl FnOnce(bool) + Send + 'static) {
    let tx = FOCUS_CHECKS.get_or_init(|| {
        let (tx, rx) = mpsc::sync_channel::<Check>(1);
        thread::spawn(move || unsafe {
            if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
                return;
            }
            if let Ok(automation) =
                CoCreateInstance::<_, IUIAutomation>(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
            {
                while let Ok((x, y, reply)) = rx.recv() {
                    // Let the target application process the injected mouse-up.
                    thread::sleep(Duration::from_millis(100));
                    reply(editable_at(&automation, POINT { x, y }).unwrap_or(false));
                }
            }
            CoUninitialize();
        });
        tx
    });
    let _ = tx.try_send((x, y, Box::new(reply)));
}

unsafe fn editable_at(automation: &IUIAutomation, point: POINT) -> windows::core::Result<bool> {
    let focused = automation.GetFocusedElement()?;
    if !focused.CurrentIsEnabled()?.as_bool()
        || focused.CurrentControlType()? != UIA_EditControlTypeId
    {
        return Ok(false);
    }
    if let Ok(value) = focused.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId) {
        if value.CurrentIsReadOnly()?.as_bool() {
            return Ok(false);
        }
    }
    let walker = automation.RawViewWalker()?;
    let mut hit = automation.ElementFromPoint(point)?;
    for _ in 0..12 {
        if automation.CompareElements(&focused, &hit)?.as_bool() {
            return Ok(true);
        }
        hit = walker.GetParentElement(&hit)?;
    }
    Ok(false)
}
