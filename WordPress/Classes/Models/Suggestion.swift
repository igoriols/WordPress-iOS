import Foundation

@objcMembers public class Suggestion: NSObject {
    let userLogin: String?
    let displayName: String?
    let imageURL: URL?

    init(dictionary: [String: Any]) {
        userLogin = dictionary["user_login"] as? String
        displayName = dictionary["display_name"] as? String
        if let imageURLString = dictionary["image_URL"] as? String {
            imageURL = URL(string: imageURLString)
        } else {
            imageURL = nil
        }
    }

    public func cachedAvatar(with size: CGSize) -> UIImage? {
        var hash: NSString?
        let type = avatarSourceType(with: &hash)

        if let hash = hash, let type = type {
            return WPAvatarSource.shared()?.cachedImage(forAvatarHash: hash as String, of: type, with: size)
        }
        return nil
    }

    public func fetchAvatar(with size: CGSize, success: ((UIImage?) -> Void)?) {
        var hash: NSString?
        let type = avatarSourceType(with: &hash)

        if let hash = hash, let type = type, let success = success {
            WPAvatarSource.shared()?.fetchImage(forAvatarHash: hash as String, of: type, with: size, success: success)
        } else {
            success?(nil)
        }
    }

    func avatarSourceType(with hash: inout NSString?) -> WPAvatarSourceType? {
        if let imageURL = imageURL {
            return WPAvatarSource.shared()?.parseURL(imageURL, forAvatarHash: &hash)
        }
        return .unknown
    }
}
