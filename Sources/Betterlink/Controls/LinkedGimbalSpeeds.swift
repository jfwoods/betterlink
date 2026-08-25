import SwiftUI

/// The two speed ceilings and the chain link between them, as a bundle of
/// bindings.
///
/// Two surfaces edit these — the Dashboard's control bar and the Settings
/// pane's gimbal section — and both bind the same `Preferences` keys through
/// `@AppStorage`, so a change on either shows up immediately on the other.
/// What "linked" *means* lives here rather than in each of them, because two
/// copies of this coupling would eventually stop agreeing.
struct LinkedGimbalSpeeds {
    let panCap: Binding<Double>
    let tiltCap: Binding<Double>
    let isLinked: Binding<Bool>

    init(pan: Binding<Double>, tilt: Binding<Double>, linked: Binding<Bool>) {
        panCap = pan
        tiltCap = tilt
        isLinked = linked
    }

    /// Bind sliders to these, not to the raw preferences: while the link is
    /// on, moving either one moves both — which is the single-slider behavior
    /// this replaced, and the default.
    var pan: Binding<Double> {
        Binding {
            panCap.wrappedValue
        } set: { value in
            panCap.wrappedValue = value
            if isLinked.wrappedValue { tiltCap.wrappedValue = value }
        }
    }

    var tilt: Binding<Double> {
        Binding {
            tiltCap.wrappedValue
        } set: { value in
            tiltCap.wrappedValue = value
            if isLinked.wrappedValue { panCap.wrappedValue = value }
        }
    }

    var link: Binding<Bool> {
        Binding {
            isLinked.wrappedValue
        } set: { linked in
            isLinked.wrappedValue = linked
            // Linking two sliders that are apart has to resolve to one of
            // them, or the reading underneath describes a speed nobody chose.
            // Pan wins, being the axis with the wider hardware range.
            if linked { tiltCap.wrappedValue = panCap.wrappedValue }
        }
    }
}
