//! Android Wireless debugging QR payload construction.

/// An error returned when a value cannot be represented safely in the ADB QR
/// payload grammar.
#[derive(Debug, Eq, PartialEq)]
pub enum PairingPayloadError {
    EmptyServiceName,
    EmptySecret,
    ReservedCharacter,
}

/// Builds the QR content consumed by Android's "Pair device with QR code" flow.
///
/// The caller is responsible for generating an unguessable service name and
/// temporary secret. This function deliberately refuses delimiter characters so
/// one field cannot alter another field in the payload.
pub fn qr_payload(service_name: &str, secret: &str) -> Result<String, PairingPayloadError> {
    validate_field(service_name, PairingPayloadError::EmptyServiceName)?;
    validate_field(secret, PairingPayloadError::EmptySecret)?;

    Ok(format!("WIFI:T:ADB;S:{service_name};P:{secret};;"))
}

fn validate_field(
    value: &str,
    empty_error: PairingPayloadError,
) -> Result<(), PairingPayloadError> {
    if value.is_empty() {
        return Err(empty_error);
    }

    if value
        .chars()
        .any(|character| matches!(character, ';' | ':' | '\n' | '\r'))
    {
        return Err(PairingPayloadError::ReservedCharacter);
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{PairingPayloadError, qr_payload};

    #[test]
    fn formats_a_valid_adb_qr_payload() {
        assert_eq!(
            qr_payload("_adb-tls-pairing._tcp.example", "temporary-secret"),
            Ok("WIFI:T:ADB;S:_adb-tls-pairing._tcp.example;P:temporary-secret;;".to_owned())
        );
    }

    #[test]
    fn rejects_empty_and_delimiter_bearing_fields() {
        assert_eq!(
            qr_payload("", "secret"),
            Err(PairingPayloadError::EmptyServiceName)
        );
        assert_eq!(
            qr_payload("service", ""),
            Err(PairingPayloadError::EmptySecret)
        );
        assert_eq!(
            qr_payload("service;extra", "secret"),
            Err(PairingPayloadError::ReservedCharacter)
        );
        assert_eq!(
            qr_payload("service", "secret\nextra"),
            Err(PairingPayloadError::ReservedCharacter)
        );
    }
}
