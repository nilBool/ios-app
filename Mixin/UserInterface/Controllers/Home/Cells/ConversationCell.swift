import UIKit
import SDWebImage

class ConversationCell: UITableViewCell {

    static let cellIdentifier = "cell_identifier_conversation"

    @IBOutlet weak var iconImageView: AvatarImageView!
    @IBOutlet weak var nameLabel: UILabel!
    @IBOutlet weak var contentLabel: UILabel!
    @IBOutlet weak var muteImageView: UIImageView!
    @IBOutlet weak var timeLabel: UILabel!
    @IBOutlet weak var messageTypeImageView: UIImageView!
    @IBOutlet weak var unreadLabel: InsetLabel!
    @IBOutlet weak var messageStatusImageView: UIImageView!
    @IBOutlet weak var verifiedImageView: UIImageView!
    @IBOutlet weak var pinImageView: UIImageView!

    override func prepareForReuse() {
        super.prepareForReuse()
        iconImageView?.sd_cancelCurrentImageLoad()
    }

    func render(item: ConversationItem) {
        if item.category == ConversationCategory.CONTACT.rawValue {
            iconImageView.setImage(with: item.ownerAvatarUrl, identityNumber: item.ownerIdentityNumber, name: item.ownerFullName)
        } else {
            iconImageView.setGroupImage(with: item.iconUrl, conversationId: item.conversationId)
        }
        nameLabel.text = item.getConversationName()
        timeLabel.text = item.createdAt.toUTCDate().timeAgo()

        if item.ownerIsVerified {
            verifiedImageView.image = #imageLiteral(resourceName: "ic_user_verified")
            verifiedImageView.isHidden = false
        } else if item.ownerIsBot {
            verifiedImageView.image = #imageLiteral(resourceName: "ic_user_bot")
            verifiedImageView.isHidden = false
        } else {
            verifiedImageView.isHidden = true
        }

        if item.messageStatus == MessageStatus.FAILED.rawValue {
            messageStatusImageView.isHidden = false
            messageStatusImageView.image = #imageLiteral(resourceName: "ic_status_sending")
            messageTypeImageView.isHidden = true
            contentLabel.text = Localized.CHAT_DECRYPTION_FAILED_HINT(username: item.senderFullName)
        } else {
            showMessageIndicate(conversation: item)
            let senderName = item.senderId == AccountAPI.shared.accountUserId ? Localized.CHAT_MESSAGE_YOU : item.senderFullName

            let category = item.contentType
            if category.hasSuffix("_TEXT") {
                if item.isGroup() {
                    contentLabel.text = "\(senderName): \(item.content)"
                } else {
                    contentLabel.text = item.content
                }
                messageTypeImageView.isHidden = true
            } else if category.hasSuffix("_IMAGE") {
                if item.isGroup() {
                    contentLabel.text = "\(senderName): \(Localized.NOTIFICATION_CONTENT_PHOTO)"
                } else {
                    contentLabel.text = Localized.NOTIFICATION_CONTENT_PHOTO
                }
                messageTypeImageView.image = #imageLiteral(resourceName: "ic_message_photo")
                messageTypeImageView.isHidden = false
            } else if category.hasSuffix("_STICKER") {
                if item.isGroup() {
                    contentLabel.text = "\(senderName): \(Localized.NOTIFICATION_CONTENT_STICKER)"
                } else {
                    contentLabel.text = Localized.NOTIFICATION_CONTENT_STICKER
                }
                messageTypeImageView.image = #imageLiteral(resourceName: "ic_message_photo")
                messageTypeImageView.isHidden = false
            } else if category.hasSuffix("_CONTACT") {
                if item.isGroup() {
                    contentLabel.text = "\(senderName): \(Localized.NOTIFICATION_CONTENT_CONTACT)"
                } else {
                    contentLabel.text = Localized.NOTIFICATION_CONTENT_CONTACT
                }
                messageTypeImageView.image = #imageLiteral(resourceName: "ic_message_contact")
                messageTypeImageView.isHidden = false
            } else if category.hasSuffix("_DATA") {
                if item.isGroup() {
                    contentLabel.text = "\(senderName): \(Localized.NOTIFICATION_CONTENT_FILE)"
                } else {
                    contentLabel.text = Localized.NOTIFICATION_CONTENT_FILE
                }
                messageTypeImageView.image = #imageLiteral(resourceName: "ic_message_file")
                messageTypeImageView.isHidden = false
            } else if category == MessageCategory.SYSTEM_ACCOUNT_SNAPSHOT.rawValue {
                contentLabel.text = Localized.NOTIFICATION_CONTENT_TRANSFER
                messageTypeImageView.image = #imageLiteral(resourceName: "ic_message_transfer")
                messageTypeImageView.isHidden = false
            } else if category == MessageCategory.APP_BUTTON_GROUP.rawValue {
                contentLabel.text = (item.appButtons?.map({ (appButton) -> String in
                    return "[\(appButton.label)]"
                }) ?? []).joined()
                messageTypeImageView.image = #imageLiteral(resourceName: "ic_message_bot_menu")
                messageTypeImageView.isHidden = false
            } else {
                if item.contentType.hasPrefix("SYSTEM_") {
                    contentLabel.text = SystemConversationAction.getSystemMessage(actionName: item.actionName, userId: item.senderId, userFullName: item.senderFullName, participantId: item.participantUserId, participantFullName: item.participantFullName, content: item.content)
                } else {
                    contentLabel.text = ""
                }
                messageTypeImageView.isHidden = true
            }
        }
        
        if item.unseenMessageCount > 0 {
            unreadLabel.isHidden = false
            unreadLabel.text = "\(item.unseenMessageCount)"
            pinImageView.isHidden = true
        } else {
            unreadLabel.isHidden = true
            pinImageView.isHidden = item.pinTime == nil
        }

        muteImageView.isHidden = !item.isMuted
    }

    private func showMessageIndicate(conversation: ConversationItem) {
        guard conversation.senderId == AccountAPI.shared.accountUserId, !conversation.contentType.hasPrefix("SYSTEM_") else {
            messageStatusImageView.isHidden = true
            return
        }
        messageStatusImageView.isHidden = false
        switch conversation.messageStatus {
        case MessageStatus.SENDING.rawValue:
            messageStatusImageView.image = #imageLiteral(resourceName: "ic_status_sending")
        case MessageStatus.SENT.rawValue:
            messageStatusImageView.image = #imageLiteral(resourceName: "ic_status_sent")
        case MessageStatus.DELIVERED.rawValue:
            messageStatusImageView.image = #imageLiteral(resourceName: "ic_status_delivered")
        case MessageStatus.READ.rawValue:
            messageStatusImageView.image = #imageLiteral(resourceName: "ic_status_read")
        default:
            messageStatusImageView.isHidden = true
        }
    }

}
