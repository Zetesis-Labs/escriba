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

#[cfg(target_os = "linux")]
mod linux {
    use super::Notification;

    pub fn desktop(notification: &Notification) -> notify_rust::Notification {
        let mut desktop = notify_rust::Notification::new();
        desktop
            .appname("Escriba")
            .summary(&notification.title)
            .body(&notification.body);
        if notification.sound {
            desktop.sound_name("message-new-instant");
        }
        desktop
    }

    /// Desktop notifications need no permission on Linux.
    pub fn request_authorization() -> Result<(), String> {
        Ok(())
    }

    // Like macOS, sending does not wait for the desktop to show it.
    pub fn send(notification: &Notification) -> Result<(), String> {
        let desktop = desktop(notification);
        std::thread::Builder::new()
            .name("notificación".into())
            .spawn(move || {
                if let Err(error) = desktop.show() {
                    eprintln!("No se pudo mostrar la notificación: {error}");
                }
            })
            .map(|_| ())
            .map_err(|error| format!("No se pudo enviar la notificación: {error}"))
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn la_notificacion_del_escritorio_lleva_titulo_cuerpo_y_sonido_si_toca() {
            let sounding = desktop(&Notification {
                title: "Nota transcrita".into(),
                body: "Reunión del jueves".into(),
                sound: true,
            });
            assert_eq!(sounding.appname, "Escriba");
            assert_eq!(sounding.summary, "Nota transcrita");
            assert_eq!(sounding.body, "Reunión del jueves");
            assert!(sounding
                .hints
                .contains(&notify_rust::Hint::SoundName("message-new-instant".into())));
            let silent = desktop(&Notification {
                title: "t".into(),
                body: "b".into(),
                sound: false,
            });
            assert!(silent.hints.is_empty());
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::{request_authorization, send};

#[cfg(windows)]
pub fn request_authorization() -> Result<(), String> {
    Ok(())
}
#[cfg(windows)]
pub fn send(notification: &Notification) -> Result<(), String> {
    use winrt_notification::{Sound, Toast};
    let toast = Toast::new("dev.zetesis.escriba.tauri")
        .title(&notification.title)
        .text1(&notification.body)
        .sound(if notification.sound {
            Some(Sound::Default)
        } else {
            None
        });
    toast.show().map_err(|error| error.to_string())
}
