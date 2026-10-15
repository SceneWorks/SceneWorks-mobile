/// The boundary between the app and the image-generation engine.
///
/// The app talks only to this protocol. The real on-device engine (Rust/MLX behind an FFI) arrives later; until then
/// the app's own stories define its requirements and provide in-process implementations for previews and tests.
protocol GenerationEngine: Sendable {}
