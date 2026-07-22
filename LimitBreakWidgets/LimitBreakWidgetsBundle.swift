import SwiftUI
import WidgetKit

@main
struct LimitBreakWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SkillMatrixWidget()
        RecordBoardWidget()
        StreakWidget()
        SessionLiveActivity()
    }
}
