# Security

SpaceKeeper needs powerful macOS permissions (Accessibility and, optionally, Screen Recording), so security reports are
taken seriously.

If you find a vulnerability, please **don't open a public issue**. Email **techmaleek@gmail.com** with details and steps
to reproduce. You'll get a reply as soon as possible, and credit in the release notes if you'd like it.

What SpaceKeeper does *not* do: it collects no analytics and never stores or transmits screen contents. The only network
request it makes is the feedback form, and only when you press **Send**: your message, optional reply email and optional
screenshot are posted over HTTPS to formsubmit.co, which emails them to the author. If you turn on update checks (or choose
**Check for Updates…**), it also makes an anonymous HTTPS GET to `api.github.com` for the latest release; nothing about you
or your Mac is sent beyond what any web request carries. Links in the About window open your browser.
