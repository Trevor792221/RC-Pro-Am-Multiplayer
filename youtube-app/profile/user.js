// Preferences for the dedicated YouTube App profile.
// The installer fills in __UA__ and __URL__ and copies this file into the profile.

// Load chrome/userChrome.css and chrome/userContent.css.
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);

// Enable add-ons dropped into the profile's extensions folder (uBlock Origin).
user_pref("extensions.autoDisableScopes", 0);

// The user agent picks which YouTube layout is served (mobile app or TV app).
user_pref("general.useragent.override", "__UA__");

// Always start on YouTube, without restoring old sessions.
user_pref("browser.startup.homepage", "__URL__");
user_pref("browser.startup.page", 1);
user_pref("browser.sessionstore.resume_from_crash", false);

// Behave like a single-window app: open links in the same window.
user_pref("browser.link.open_newwindow", 1);
user_pref("browser.link.open_newwindow.restriction", 0);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.closeWindowWithLastTab", true);

// Use the window manager's title bar, since the tab strip is hidden.
user_pref("browser.tabs.inTitlebar", 0);

// Dark theme for web content, like the YouTube app's default look.
user_pref("layout.css.prefers-color-scheme.content-override", 0);

// No first-run pages, default-browser nags or telemetry prompts.
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("startup.homepage_override_url", "");
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
user_pref("extensions.pocket.enabled", false);
user_pref("browser.translations.automaticallyPopup", false);

// Media: allow autoplay and skip the fullscreen warning.
user_pref("media.autoplay.default", 0);
user_pref("full-screen-api.warning.timeout", 0);
user_pref("full-screen-api.transition-duration.enter", "0 0");
user_pref("full-screen-api.transition-duration.leave", "0 0");
