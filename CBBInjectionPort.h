//
//  CBBInjectionPort.h
//  CardboardOS
//
//  The one piece of the tweak both processes have to agree on. Kept C-only and
//  free of UIKit so the backboardd half can include it without dragging a UI
//  framework into a daemon.
//
//  Why a file and not a message port: CFMessagePort registers its name in the
//  process's own bootstrap namespace, and backboardd runs in a different one -
//  the first attempt to open a port there failed with "could not create the
//  injection port". The preferences directory, by contrast, is writable by both
//  (the breadcrumbs land in it from backboardd already), so the queue is a plain
//  append-only file there and each side only has to agree on its format.
//

#ifndef CBBInjectionPort_h
#define CBBInjectionPort_h

// One line per digitizer event: "<phase> <x> <y> [client type] [sender strategy]\n",
// points in fixed screen space. The last two fields are a diagnosis aid - they
// let a shell on the device force one combination without a rebuild - and are
// omitted by the tweak itself. SpringBoard truncates the file at the start of a
// gesture and appends as it goes; backboardd remembers how many bytes it has
// consumed, which makes a missed wake-up harmless: the next read picks up
// everything still there.
#define CBB_DRIVER_QUEUE_PATH "/var/mobile/Library/Preferences/com.buffy.cardboardos.inject"

// Taps aimed at the app on screen. Same idea, separate file, and the app's own
// relay dylib is the only reader: "<bundle id> <phase> <x> <y>\n". The bundle
// id is the whole addressing scheme - only the app it names acts on the line, so
// the relay can be loaded into every app without every app tapping itself.
//
// It is a bundle id and not a pid because SpringBoard answered with pid 0 for
// the app on screen (SBApplication's -pid), and a pid that no process can match
// is a tap that silently goes nowhere. The bundle id is what SpringBoard
// resolves without help, and every app knows its own.
#define CBB_RELAY_QUEUE_PATH "/var/mobile/Library/Preferences/com.buffy.cardboardos.appinject"
#define CBB_RELAY_NOTIFY_NAME "com.buffy.cardboardos.apptap"

enum {
    CBBInjectionPhaseDown = 0,
    CBBInjectionPhaseMove = 1,
    CBBInjectionPhaseUp = 2,
};

#endif /* CBBInjectionPort_h */
