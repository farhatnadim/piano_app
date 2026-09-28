import XCTest
@testable import PianoCoachCore

final class YouTubeLinkTests: XCTestCase {
    private let id = "dQw4w9WgXcQ"

    func testWatchURLs() {
        let inputs = [
            "https://www.youtube.com/watch?v=\(id)",
            "http://www.youtube.com/watch?v=\(id)",
            "https://youtube.com/watch?v=\(id)",
            "www.youtube.com/watch?v=\(id)",
            "youtube.com/watch?v=\(id)",
            "https://m.youtube.com/watch?v=\(id)",
            "https://music.youtube.com/watch?v=\(id)&list=RDAMVM\(id)",
            "https://www.youtube.com/watch?feature=share&v=\(id)&t=42s",
            "https://www.youtube.com/watch?v=\(id)#t=30",
            "HTTPS://WWW.YOUTUBE.COM/watch?v=\(id)",
            "https://www.youtube.com:443/watch?v=\(id)",
            "https://www.youtube.com/watch/?v=\(id)",
            "//www.youtube.com/watch?v=\(id)",
        ]
        for input in inputs {
            XCTAssertEqual(YouTubeLink.videoID(from: input), id, input)
        }
    }

    func testPathStyleURLs() {
        let inputs = [
            "https://www.youtube.com/embed/\(id)",
            "https://www.youtube.com/embed/\(id)?rel=0&autoplay=1",
            "https://www.youtube-nocookie.com/embed/\(id)?start=10",
            "youtube-nocookie.com/embed/\(id)",
            "https://youtube.com/shorts/\(id)?feature=share",
            "https://www.youtube.com/live/\(id)?si=abcdef",
            "https://www.youtube.com/v/\(id)?version=3",
            "https://youtu.be/\(id)",
            "youtu.be/\(id)?t=90",
            "https://youtu.be/\(id)?si=XyZ123-_abc",
            "https://youtu.be/\(id)/",
            "https://www.youtube.com/attribution_link?a=abc&u=%2Fwatch%3Fv%3D\(id)%26feature%3Dshare",
        ]
        for input in inputs {
            XCTAssertEqual(YouTubeLink.videoID(from: input), id, input)
        }
    }

    func testWhitespaceAndSurroundingText() {
        let inputs = [
            "  https://youtu.be/\(id)  \n",
            "Check this out: https://www.youtube.com/watch?v=\(id) it's great!",
            "Check this out https://youtu.be/\(id).",
            "(https://youtu.be/\(id))",
            "<https://www.youtube.com/watch?v=\(id)>",
            "\"https://youtu.be/\(id)\"",
            "Watch: youtube.com/shorts/\(id), thanks",
            "Link:https://youtu.be/\(id)",
            "first https://example.com/foo then https://youtu.be/\(id)",
        ]
        for input in inputs {
            XCTAssertEqual(YouTubeLink.videoID(from: input), id, input)
        }
    }

    func testBareID() {
        XCTAssertEqual(YouTubeLink.videoID(from: id), id)
        XCTAssertEqual(YouTubeLink.videoID(from: "  \(id)\n"), id)
        XCTAssertEqual(YouTubeLink.videoID(from: "a-b_c1234XY"), "a-b_c1234XY")
        // A bare id is only accepted as the whole input.
        XCTAssertNil(YouTubeLink.videoID(from: "watch \(id) now"))
    }

    func testRejectsNonVideos() {
        let inputs = [
            "",
            "   ",
            "hello",
            "dQw4w9WgXc",            // 10 chars
            "dQw4w9WgXcQQ",          // 12 chars
            "dQw4w9WgXc!",
            "https://www.youtube.com/",
            "https://www.youtube.com/watch?v=short",
            "https://www.youtube.com/watch?v=\(id)X",
            "https://www.youtube.com/playlist?list=PL1234567890",
            "https://www.youtube.com/embed/videoseries?list=PL1234567890",
            "https://www.youtube.com/channel/UC1234567890",
            "https://vimeo.com/123456789",
            "https://example.com/watch?v=\(id)",
            "https://notyoutube.com/watch?v=\(id)",
            "https://youtube.com.evil.example/watch?v=\(id)",
        ]
        for input in inputs {
            XCTAssertNil(YouTubeLink.videoID(from: input), input)
        }
    }

    func testStartTime() {
        XCTAssertEqual(YouTubeLink.startTime(from: "https://youtu.be/\(id)?t=90"), 90)
        XCTAssertEqual(YouTubeLink.startTime(from: "https://youtu.be/\(id)?t=90s"), 90)
        XCTAssertEqual(YouTubeLink.startTime(from: "https://www.youtube.com/watch?v=\(id)&t=1m30s"), 90)
        XCTAssertEqual(YouTubeLink.startTime(from: "https://www.youtube.com/watch?v=\(id)&t=1h2m3s"), 3723)
        XCTAssertEqual(YouTubeLink.startTime(from: "https://www.youtube.com/watch?v=\(id)#t=45"), 45)
        XCTAssertEqual(YouTubeLink.startTime(from: "https://www.youtube.com/watch?v=\(id)#t=2m"), 120)
        XCTAssertEqual(YouTubeLink.startTime(from: "https://www.youtube.com/embed/\(id)?start=12"), 12)
        XCTAssertEqual(YouTubeLink.startTime(from: "youtube.com/watch?v=\(id)&t=0"), 0)
        XCTAssertEqual(YouTubeLink.startTime(from: "Look at https://youtu.be/\(id)?si=x&t=75 !"), 75)
        XCTAssertNil(YouTubeLink.startTime(from: "https://youtu.be/\(id)"))
        XCTAssertNil(YouTubeLink.startTime(from: id))
        XCTAssertNil(YouTubeLink.startTime(from: "https://youtu.be/\(id)?t=abc"))
        XCTAssertNil(YouTubeLink.startTime(from: "https://example.com/?t=90"))
    }

    func testParseTime() {
        XCTAssertEqual(YouTubeLink.parseTime("90"), 90)
        XCTAssertEqual(YouTubeLink.parseTime("90s"), 90)
        XCTAssertEqual(YouTubeLink.parseTime("1m30s"), 90)
        XCTAssertEqual(YouTubeLink.parseTime("1m30"), 90)
        XCTAssertEqual(YouTubeLink.parseTime("1h2m3s"), 3723)
        XCTAssertEqual(YouTubeLink.parseTime("1h"), 3600)
        XCTAssertEqual(YouTubeLink.parseTime("1:30"), 90)
        XCTAssertEqual(YouTubeLink.parseTime("1:02:03"), 3723)
        XCTAssertEqual(YouTubeLink.parseTime("12.5"), 12.5)
        XCTAssertNil(YouTubeLink.parseTime(""))
        XCTAssertNil(YouTubeLink.parseTime("s"))
        XCTAssertNil(YouTubeLink.parseTime("1x"))
        XCTAssertNil(YouTubeLink.parseTime("0x10"))
        XCTAssertNil(YouTubeLink.parseTime("-5"))
        XCTAssertNil(YouTubeLink.parseTime("1..2"))
    }

    func testIsValidVideoID() {
        XCTAssertTrue(YouTubeLink.isValidVideoID(id))
        XCTAssertTrue(YouTubeLink.isValidVideoID("___________"))
        XCTAssertTrue(YouTubeLink.isValidVideoID("-----------"))
        XCTAssertFalse(YouTubeLink.isValidVideoID(""))
        XCTAssertFalse(YouTubeLink.isValidVideoID("dQw4w9WgXc"))
        XCTAssertFalse(YouTubeLink.isValidVideoID("dQw4w9WgXcQQ"))
        XCTAssertFalse(YouTubeLink.isValidVideoID("dQw4w9WgXc "))
        XCTAssertFalse(YouTubeLink.isValidVideoID("dQw4w9WgXcé"))
        XCTAssertFalse(YouTubeLink.isValidVideoID("dQw4w9WgX.Q"))
    }

    func testURLs() {
        XCTAssertEqual(YouTubeLink.watchURL(videoID: id).absoluteString, "https://www.youtube.com/watch?v=\(id)")
        XCTAssertEqual(YouTubeLink.thumbnailURL(videoID: id).absoluteString, "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        XCTAssertEqual(YouTubeLink.videoID(from: YouTubeLink.watchURL(videoID: id).absoluteString), id)
    }
}
