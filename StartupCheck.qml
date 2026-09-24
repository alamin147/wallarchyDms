import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("wallarchyDms.curlCheck", ["sh", "-c", "command -v curl >/dev/null 2>&1"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null)
                return
            }

            done({
                "title": I18n.tr("curl is required"),
                "details": I18n.tr("Install curl, then re-enable the Wallarchy plugin.")
            })
        })
    }
}
