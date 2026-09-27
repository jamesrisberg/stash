import Carbon

/// Secure event input is on while a password field (or anything else that calls
/// `EnableSecureEventInput`) has focus; nothing copied then is recorded.
public enum SecureInput {
    public static var isEnabled: Bool { IsSecureEventInputEnabled() }
}
