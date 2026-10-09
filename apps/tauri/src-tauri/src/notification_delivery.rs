use crate::notifications::Notification;

#[cfg(target_os = "macos")]
mod macos {
    use super::Notification;
    use block2::RcBlock;
    use objc2::runtime::Bool;
    use objc2_foundation::{NSBundle, NSError, NSString};
    use objc2_user_notifications::{
        UNAuthorizationOptions, UNMutableNotificationContent, UNNotificationRequest,
        UNNotificationSound, UNUserNotificationCenter,
    };

    fn available() -> bool {
        NSBundle::mainBundle().bundleIdentifier().is_some()
    }

    fn log_error(operation: &str, error: *mut NSError) {
        if let Some(error) = unsafe { error.as_ref() } {
            eprintln!(
                "No se pudo completar la operación de notificaciones {operation}: código {}",
                error.code()
            );
        }
    }

    pub fn request_authorization() -> Result<(), String> {
        if !available() {
            return Ok(());
        }
        let completion = RcBlock::new(|granted: Bool, error: *mut NSError| {
            log_error("autorización", error);
            if !granted.as_bool() && error.is_null() {
                eprintln!("Permiso de notificaciones denegado");
            }
        });
        UNUserNotificationCenter::currentNotificationCenter()
            .requestAuthorizationWithOptions_completionHandler(
                UNAuthorizationOptions::Alert | UNAuthorizationOptions::Sound,
                &completion,
            );
        Ok(())
    }

    pub fn send(notification: &Notification) -> Result<(), String> {
        if !available() {
            return Ok(());
        }
        let content = UNMutableNotificationContent::new();
        content.setTitle(&NSString::from_str(&notification.title));
        content.setBody(&NSString::from_str(&notification.body));
        if notification.sound {
            content.setSound(Some(&UNNotificationSound::defaultSound()));
        }
        let identifier = NSString::from_str(&uuid::Uuid::new_v4().to_string());
        let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
            &identifier,
            &content,
            None,
        );
        let completion = RcBlock::new(|error: *mut NSError| log_error("envío", error));
        UNUserNotificationCenter::currentNotificationCenter()
            .addNotificationRequest_withCompletionHandler(&request, Some(&completion));
        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub use macos::{request_authorization, send};

#[cfg(not(target_os = "macos"))]
pub fn request_authorization() -> Result<(), String> {
    Err("Las notificaciones nativas solo están disponibles en macOS".into())
}

#[cfg(not(target_os = "macos"))]
pub fn send(_notification: &Notification) -> Result<(), String> {
    Err("Las notificaciones nativas solo están disponibles en macOS".into())
}
