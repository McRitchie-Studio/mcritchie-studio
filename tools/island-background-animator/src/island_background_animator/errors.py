"""Expected command-line errors."""


class AnimatorError(Exception):
    """Base class for errors that should be shown without a traceback."""


class ConfigurationError(AnimatorError):
    """Raised when a job configuration violates its versioned contract."""


class InputImageError(AnimatorError):
    """Raised when an input is missing, corrupt, or unsupported."""


class JobInitializationError(AnimatorError):
    """Raised when a job directory cannot be initialized safely."""
