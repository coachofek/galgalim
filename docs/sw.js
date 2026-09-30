// Service worker מינימלי: מאפשר התקנה למסך הבית.
// תמיד מהרשת — נתונים חיים מגיעים מ-Supabase ואין טעם לשמור עותק ישן של האפליקציה.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
