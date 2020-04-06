//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public class NewGroupConfirmViewController: OWSViewController {

    // MARK: - Dependencies

    private var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    private var contactsManager: OWSContactsManager {
        return Environment.shared.contactsManager
    }

    private var messageSender: MessageSender {
        return SSKEnvironment.shared.messageSender
    }

    private var tsAccountManager: TSAccountManager {
        return .sharedInstance()
    }

    // MARK: -

    private var newGroupState = NewGroupState()

    private var groupSeed: NewGroupSeed {
        return newGroupState.groupSeed
    }

    private var recipientSet: OrderedSet<PickedRecipient> {
        return newGroupState.recipientSet
    }

    private let helper: GroupAttributesEditorHelper

    private var nameTextField: UITextField {
        return helper.nameTextField
    }

    private let recipientTableView = OWSTableViewController()

    required init(newGroupState: NewGroupState) {
        self.newGroupState = newGroupState

        let groupId = newGroupState.groupSeed.possibleGroupId
        let conversationColorName = newGroupState.groupSeed.possibleConversationColorName
        self.helper = GroupAttributesEditorHelper(groupId: groupId,
                                                  conversationColorName: conversationColorName.rawValue,
                                                  groupNameOriginal: newGroupState.groupName,
                                                  avatarOriginalData: newGroupState.avatarData,
                                                  iconViewSize: 64)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message:"use other constructor instead.")
    @objc
    public required init(coder aDecoder: NSCoder) {
        notImplemented()
    }

    // MARK: - View Lifecycle

    @objc
    public override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("NEW_GROUP_NAME_GROUP_VIEW_TITLE",
                                  comment: "The title for the 'name new group' view.")

        view.backgroundColor = Theme.backgroundColor

        navigationItem.rightBarButtonItem = UIBarButtonItem(title: NSLocalizedString("NEW_GROUP_CREATE_BUTTON",
                                                                                     comment: "The title for the 'create group' button."),
                                                            style: .plain,
                                                            target: self,
                                                            action: #selector(createNewGroup),
                                                            accessibilityIdentifier: UIView.accessibilityIdentifier(in: self, name: "create"))

        // First section.

        helper.delegate = self
        helper.buildContents(avatarViewHelperDelegate: self)

        helper.avatarWrapper.setContentHuggingVerticalHigh()
        helper.nameTextField.setContentHuggingHorizontalLow()
        let firstSection = UIStackView(arrangedSubviews: [
            helper.avatarWrapper,
            helper.nameTextField
        ])
        firstSection.axis = .horizontal
        firstSection.alignment = .center
        firstSection.spacing = 12
        firstSection.isLayoutMarginsRelativeArrangement = true
        firstSection.preservesSuperviewLayoutMargins = true
        view.addSubview(firstSection)
        firstSection.autoPinWidthToSuperview()
        firstSection.autoPin(toTopLayoutGuideOf: self, withInset: 0)

        addChild(recipientTableView)
        view.addSubview(recipientTableView.view)

        recipientTableView.view.autoPinEdge(toSuperviewSafeArea: .leading)
        recipientTableView.view.autoPinEdge(toSuperviewSafeArea: .trailing)
        recipientTableView.view.autoPinEdge(.top, to: .bottom, of: firstSection)
        autoPinView(toBottomOfViewControllerOrKeyboard: recipientTableView.view, avoidNotch: false)

        updateTableContents()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        nameTextField.becomeFirstResponder()
    }

    // MARK: -

    private func updateTableContents() {
        let section = OWSTableSection()
        section.headerTitle = NSLocalizedString("GROUP_MEMBERS_SECTION_TITLE_MEMBERS",
                                                comment: "Title for the 'members' section of the 'group members' view.")

        let members = databaseStorage.uiRead { transaction in
            BaseGroupMemberViewController.orderedMembers(recipientSet: self.recipientSet, transaction: transaction)
        }.compactMap { $0.address }
        for address in members {
            section.add(OWSTableItem(
                customCellBlock: {
                    let cell = ContactTableViewCell()

                    cell.selectionStyle = .none

                    cell.configure(withRecipientAddress: address)

                    return cell
                },
                customRowHeight: UITableView.automaticDimension))
        }

        let contents = OWSTableContents()
        contents.addSection(section)
        recipientTableView.contents = contents
    }

    // MARK: - Actions

    @objc
    func createNewGroup() {
        AssertIsOnMainThread()

        guard let localAddress = tsAccountManager.localAddress else {
            owsFailDebug("missing local address")
            return
        }

        guard let groupName = newGroupState.groupName,
            !groupName.isEmpty else {
                Self.showMissingGroupNameAlert()
             return
        }
        let avatarData = newGroupState.avatarData
        let memberSet = Set([localAddress] + recipientSet.orderedMembers.compactMap { $0.address })
        let members = Array(memberSet)
        let newGroupSeed = groupSeed

        // GroupsV2 TODO: Should we allow cancel here?
        ModalActivityIndicatorViewController.present(fromViewController: self,
                                                     canCancel: false) { modalActivityIndicator in
                                                        firstly {
                                                            GroupManager.localCreateNewGroup(members: members,
                                                                                             groupId: nil,
                                                                                             name: groupName,
                                                                                             avatarData: avatarData,
                                                                                             newGroupSeed: newGroupSeed,
                                                                                             shouldSendMessage: true)
                                                        }.done { groupThread in
                                                            SignalApp.shared().presentConversation(for: groupThread,
                                                                                                   action: .compose,
                                                                                                   animated: false)
                                                            self.presentingViewController?.dismiss(animated: true)
                                                        }.catch { error in
                                                            owsFailDebug("Could not create group: \(error)")

                                                            modalActivityIndicator.dismiss {
                                                                // Partial success could create the group on the service.
                                                                // This would cause retries to fail with 409.  Therefore
                                                                // we must rotate the seed after every failure.
                                                                self.newGroupState.generateNewSeed()

                                                                NewGroupViewController.showCreateErrorUI(error: error)
                                                            }
                                                        }.retainUntilComplete()
        }
    }

    public class func showCreateErrorUI(error: Error) {
        AssertIsOnMainThread()

        if error.isNetworkFailureOrTimeout {
            OWSActionSheets.showActionSheet(title: NSLocalizedString("NEW_GROUP_CREATION_FAILED_DUE_TO_NETWORK",
                                                                     comment: "Error indicating that a new group could not be created due to network connectivity problems."))
            return
        }

        OWSActionSheets.showActionSheet(title: NSLocalizedString("NEW_GROUP_CREATION_FAILED",
                                                                 comment: "Error indicating that a new group could not be created."))
    }

    public class func showMissingGroupNameAlert() {
        AssertIsOnMainThread()

        OWSActionSheets.showActionSheet(title: NSLocalizedString("NEW_GROUP_CREATION_MISSING_NAME_ALERT_TITLE",
                                                                 comment: "Title for error alert indicating that a group name is required."),
                                        message: NSLocalizedString("NEW_GROUP_CREATION_MISSING_NAME_ALERT_MESSAGE",
                                                                 comment: "Message for error alert indicating that a group name is required."))
    }
}

// MARK: -

extension NewGroupConfirmViewController: AvatarViewHelperDelegate {
    public func avatarActionSheetTitle() -> String? {
        return NSLocalizedString("NEW_GROUP_ADD_PHOTO_ACTION", comment: "Action Sheet title prompting the user for a group avatar")
    }

    public func avatarDidChange(_ image: UIImage) {
        helper.setAvatarImage(image)
    }

    public func fromViewController() -> UIViewController {
        return self
    }

    public func hasClearAvatarAction() -> Bool {
        return true
    }

    public func clearAvatar() {
        helper.setAvatarImage(nil)
    }

    public func clearAvatarActionLabel() -> String {
        return NSLocalizedString("EDIT_GROUP_CLEAR_AVATAR", comment: "The 'clear avatar' button in the 'edit group' view.")
    }
}

// MARK: -

extension NewGroupConfirmViewController: GroupAttributesEditorHelperDelegate {
    func groupAttributesEditorContentsDidChange() {
        newGroupState.groupName = helper.groupNameCurrent
        newGroupState.avatarData = helper.avatarCurrent?.imageData
    }
}
