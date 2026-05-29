// Turbo drives the admin UI's data-turbo-confirm dialogs and the
// data-turbo-method DELETE on the Logout link. Without this import those
// silently no-op (destructive actions fire with no confirmation; logout
// issues a GET that has no matching route).
import "@hotwired/turbo-rails"
import "chartkick"
import "Chart.bundle"
