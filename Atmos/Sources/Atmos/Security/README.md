# Keychain storage

Atmos stores the OpenAI and Krisp credentials in separate macOS Keychain items under `com.evoai.atmos.openai` and `com.evoai.atmos.krisp`. It can read an existing OpenAI key from the legacy `com.chosen.mac.openai` service. Saving a key writes to the Atmos item. Background reads are noninteractive. The Reconnect controls let macOS authorize an updated build.

The Krisp key belongs to the user of this local Mac app. It mints short-lived Voice Isolation session tokens. For a deployment using a shared service credential, mint tokens on your backend.
