//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import SignalServiceKit
import ZKGroup

// Represents a proposed set of changes to a group.
//
// There are up to three group revisions involved:
//
// * "old" (e.g. oldGroupModel): the group model before the changes were made.
// * "modified" (e.g. modifiedGroupModel): the group model after the changes were made.
// * "current" (e.g. currentGroupModel): the group model at the time we apply the changes.
//
// Example:
//
// * User edits a group at "old" revision N.
// * Client diff against a "modified" group model and determines that the title changed
//   and captures that in this instance.
// * We try to update the group on the service, computing a GroupChange proto against
//   the latest known revision N.
// * Another client has made (possibly conflicting) changes. Group is now at revision
//   N+1 on service.
// * We try again, computing a new GroupChange proto against revision N+1.
//
// This class serves two roles:
//
// * To capture the user intent (i.e. the difference between "old" and "modified").
// * To try to generate a "change" proto that applies that intent to the latest group state.
//
// The latter can be non-trivial:
//
// * If we try to add a new member and another user beats us to it, we'll throw
//   GroupsV2Error.redundantChange when computing a GroupChange proto.
// * If we add (alice and bob) but another user adds (alice) first, we'll just add (bob).
@objc
public class GroupsV2ChangeSetImpl: NSObject, GroupsV2ChangeSet {

    // MARK: - Dependencies

    private var groupsV2: GroupsV2 {
        return SSKEnvironment.shared.groupsV2
    }

    private var tsAccountManager: TSAccountManager {
        return TSAccountManager.sharedInstance()
    }

    // MARK: -

    public let groupId: Data
    public let groupSecretParamsData: Data

    // MARK: - These properties capture the original intent of the local user.

    // Non-nil if the title changed.
    // When clearing the title, this will be the empty string.
    private var title: String?

    private var membersToAdd = [UUID: GroupsProtoMemberRole]()
    private var membersToRemove = [UUID]()
    private var membersToChangeRole = [UUID: GroupsProtoMemberRole]()
    private var pendingMembersToAdd = [UUID: GroupsProtoMemberRole]()
    private var pendingMembersToRemove = [UUID]()

    // These access properties should only be set if the value is changing.
    private var accessForMembers: GroupV2Access?
    private var accessForAttributes: GroupV2Access?

    @objc
    public required init(for groupModel: TSGroupModel) throws {
        guard groupModel.groupsVersion == .V2 else {
            throw OWSAssertionError("Invalid groupsVersion.")
        }
        self.groupId = groupModel.groupId
        guard let groupSecretParamsData = groupModel.groupSecretParamsData else {
            throw OWSAssertionError("Missing groupSecretParamsData.")
        }
        self.groupSecretParamsData = groupSecretParamsData
    }

    // MARK: - Original Intent

    // Calculate the intended changes of the local user
    // by diffing two group models.
    @objc
    public func buildChangeSet(from oldGroupModel: TSGroupModel,
                               to newGroupModel: TSGroupModel,
                               transaction: SDSAnyReadTransaction) throws {

        if oldGroupModel.groupName != newGroupModel.groupName {
            setTitle(newGroupModel.groupName)
        }
        guard groupId == oldGroupModel.groupId else {
            throw OWSAssertionError("Mismatched groupId.")
        }
        guard groupId == newGroupModel.groupId else {
            throw OWSAssertionError("Mismatched groupId.")
        }

        let oldGroupMembership = oldGroupModel.groupMembership
        let newGroupMembership = newGroupModel.groupMembership

        let oldUserUuids = Set(oldGroupMembership.allUsers.compactMap { $0.uuid })
        let newUserUuids = Set(newGroupMembership.allUsers.compactMap { $0.uuid })

        for uuid in newUserUuids.subtracting(oldUserUuids) {
            let isAdministrator = newGroupMembership.isAdministrator(SignalServiceAddress(uuid: uuid))
            let isPending = newGroupMembership.isPending(SignalServiceAddress(uuid: uuid))
            let role: GroupsProtoMemberRole = isAdministrator ? .administrator : .`default`
            if isPending {
                addPendingMember(uuid, role: role)
            } else {
                addMember(uuid, role: role)
            }
        }

        for uuid in oldUserUuids.subtracting(newUserUuids) {
            let wasPending = oldGroupMembership.isPending(SignalServiceAddress(uuid: uuid))
            if wasPending {
                removePendingMember(uuid)
            } else {
                removeMember(uuid)
            }
        }

        // GroupsV2 TODO: We don't try to add a non-pending member if user is already a pending member.
        // GroupsV2 TODO: We don't try to add a pending member if user is already a non-pending member.
        // GroupsV2 TODO: We don't try to change the role of pending members.

        // GroupsV2 TODO: Calculate membersToInvite.
        // Don't include already-invited members.
        // Persist list of invited members on TSGroupModel.

        let oldMemberUuids = Set(oldGroupMembership.allMembers.compactMap { $0.uuid })
        let newMemberUuids = Set(newGroupMembership.allMembers.compactMap { $0.uuid })
        for uuid in oldMemberUuids.intersection(newMemberUuids) {
            let address = SignalServiceAddress(uuid: uuid)
            let oldIsAdministrator = oldGroupMembership.isAdministrator(address)
            let newIsAdministrator = newGroupMembership.isAdministrator(address)
            guard oldIsAdministrator != newIsAdministrator else {
                continue
            }
            let role: GroupsProtoMemberRole = newIsAdministrator ? .administrator : .`default`
            changeRoleForMember(uuid, role: role)
        }

        guard let oldAccess = oldGroupModel.groupAccess else {
            throw OWSAssertionError("Missing groupAccess.")
        }
        guard let newAccess = newGroupModel.groupAccess else {
            throw OWSAssertionError("Missing groupAccess.")
        }
        if oldAccess.member != newAccess.member {
            self.accessForMembers = newAccess.member
        }
        if oldAccess.attributes != newAccess.attributes {
            self.accessForAttributes = newAccess.attributes
        }

        // GroupsV2 TODO: Calculate other changed state, e.g. avatar.
    }

    @objc
    public func setTitle(_ value: String?) {
        assert(self.title == nil)
        // Non-nil if the title changed.
        self.title = value ?? ""
    }

    @objc
    public func addNormalMember(_ uuid: UUID) {
        addMember(uuid, role: .default)
    }

    @objc
    public func addAdministrator(_ uuid: UUID) {
        addMember(uuid, role: .administrator)
    }

    public func addMember(_ uuid: UUID, role: GroupsProtoMemberRole) {
        assert(membersToAdd[uuid] == nil)
        membersToAdd[uuid] = role
    }

    @objc
    public func removeMember(_ uuid: UUID) {
        assert(!membersToRemove.contains(uuid))
        membersToRemove.append(uuid)
    }

    public func changeRoleForMember(_ uuid: UUID, role: GroupsProtoMemberRole) {
        assert(membersToChangeRole[uuid] == nil)
        membersToChangeRole[uuid] = role
    }

    public func addPendingMember(_ uuid: UUID, role: GroupsProtoMemberRole) {
        assert(pendingMembersToAdd[uuid] == nil)
        pendingMembersToAdd[uuid] = role
    }

    public func removePendingMember(_ uuid: UUID) {
        assert(!pendingMembersToRemove.contains(uuid))
        pendingMembersToRemove.append(uuid)
    }

    // MARK: - Change Protos

    private typealias ProfileKeyCredentialMap = [UUID: ProfileKeyCredential]

    // Given the "current" group state, build a change proto that
    // reflects the elements of the "original intent" that are still
    // necessary to perform.
    public func buildGroupChangeProto(currentGroupModel: TSGroupModel) -> Promise<GroupsProtoGroupChangeActions> {
        guard groupId == currentGroupModel.groupId else {
            return Promise(error: OWSAssertionError("Mismatched groupId."))
        }
        guard let groupsV2Impl = groupsV2 as? GroupsV2Impl else {
            return Promise(error: OWSAssertionError("Invalid groupsV2: \(type(of: groupsV2))"))
        }

        // Note that we're calculating the set of users for whom we need
        // profile key credentials for based on the "original intent".
        // We could slightly optimize by only gathering profile key
        // credentials that we'll actually need to build the change proto.
        //
        // NOTE: We don't (and can't) gather profile key credentials for pending members.
        //
        // GroupsV2 TODO: Do we need to gather profile key credentials for other actions as well?
        var uuidsForProfileKeyCredentials = Set<UUID>()
        uuidsForProfileKeyCredentials.formUnion(membersToAdd.keys)
        let addressesForProfileKeyCredentials: [SignalServiceAddress] = uuidsForProfileKeyCredentials.map { SignalServiceAddress(uuid: $0) }

        return groupsV2Impl.tryToEnsureProfileKeyCredentials(for: addressesForProfileKeyCredentials)
            .then { (_) -> Promise<ProfileKeyCredentialMap> in
                return groupsV2Impl.loadProfileKeyCredentialData(for: Array(uuidsForProfileKeyCredentials))
        }.then { (profileKeyCredentialMap: ProfileKeyCredentialMap) -> Promise<GroupsProtoGroupChangeActions> in
            return self.buildGroupChangeProto(currentGroupModel: currentGroupModel,
                                              profileKeyCredentialMap: profileKeyCredentialMap)
        }
    }

    private func buildGroupChangeProto(currentGroupModel: TSGroupModel,
                                       profileKeyCredentialMap: ProfileKeyCredentialMap) -> Promise<GroupsProtoGroupChangeActions> {
        return DispatchQueue.global().async(.promise) { () throws -> GroupsProtoGroupChangeActions in
            let groupV2Params = try GroupV2Params(groupModel: currentGroupModel)

            let actionsBuilder = GroupsProtoGroupChangeActions.builder()
            guard let localUuid = self.tsAccountManager.localUuid else {
                throw OWSAssertionError("Missing localUuid.")
            }

            let oldVersion = currentGroupModel.groupV2Revision
            let newVersion = oldVersion + 1
            Logger.verbose("Version: \(oldVersion) -> \(newVersion)")
            actionsBuilder.setVersion(newVersion)

            var didChange = false

            if let title = self.title,
                title != currentGroupModel.groupName {
                let encryptedData = try groupV2Params.encryptString(title)
                let actionBuilder = GroupsProtoGroupChangeActionsModifyTitleAction.builder()
                actionBuilder.setTitle(encryptedData)
                actionsBuilder.setModifyTitle(try actionBuilder.build())
                didChange = true
            }

            let currentGroupMembership = currentGroupModel.groupMembership
            for (uuid, role) in self.membersToAdd {
                guard !currentGroupMembership.contains(uuid) else {
                    // Another user has already added this member.
                    //
                    // GroupsV2 TODO: What if they added them with a different (lower) role?
                    continue
                }
                guard let profileKeyCredential = profileKeyCredentialMap[uuid] else {
                    throw OWSAssertionError("Missing profile key credential]: \(uuid)")
                }
                let actionBuilder = GroupsProtoGroupChangeActionsAddMemberAction.builder()
                actionBuilder.setAdded(try GroupsV2Protos.buildMemberProto(profileKeyCredential: profileKeyCredential,
                                                                           role: role,
                                                                           groupV2Params: groupV2Params))
                actionsBuilder.addAddMembers(try actionBuilder.build())
                didChange = true
            }

            for (uuid, role) in self.pendingMembersToAdd {
                guard !currentGroupMembership.contains(uuid) else {
                    // Another user has already added this member.
                    //
                    // GroupsV2 TODO: What if they added them with a different (lower) role?
                    continue
                }
                let actionBuilder = GroupsProtoGroupChangeActionsAddPendingMemberAction.builder()
                actionBuilder.setAdded(try GroupsV2Protos.buildPendingMemberProto(uuid: uuid,
                                                                                  role: role,
                                                                                  localUuid: localUuid,
                                                                                  groupV2Params: groupV2Params))
                actionsBuilder.addAddPendingMembers(try actionBuilder.build())
                didChange = true
            }

            for uuid in self.membersToRemove {
                guard currentGroupMembership.contains(uuid) else {
                    // Another user has already deleted this member.
                    continue
                }
                let actionBuilder = GroupsProtoGroupChangeActionsDeleteMemberAction.builder()
                let userId = try groupV2Params.userId(forUuid: uuid)
                actionBuilder.setDeletedUserID(userId)
                actionsBuilder.addDeleteMembers(try actionBuilder.build())
                didChange = true
            }

            for uuid in self.pendingMembersToRemove {
                guard currentGroupMembership.contains(uuid) else {
                    // Another user has already deleted this member.
                    continue
                }
                let actionBuilder = GroupsProtoGroupChangeActionsDeletePendingMemberAction.builder()
                let userId = try groupV2Params.userId(forUuid: uuid)
                actionBuilder.setDeletedUserID(userId)
                actionsBuilder.addDeletePendingMembers(try actionBuilder.build())
                didChange = true
            }

            for (uuid, role) in self.membersToChangeRole {
                guard currentGroupMembership.contains(uuid) else {
                    // Another user has already added this member.
                    //
                    // GroupsV2 TODO: What if they added them with a different (lower) role?
                    continue
                }
                let actionBuilder = GroupsProtoGroupChangeActionsModifyMemberRoleAction.builder()
                let userId = try groupV2Params.userId(forUuid: uuid)
                actionBuilder.setUserID(userId)
                actionBuilder.setRole(role)
                actionsBuilder.addModifyMemberRoles(try actionBuilder.build())
                didChange = true
            }

            guard let currentAccess = currentGroupModel.groupAccess else {
                throw OWSAssertionError("Missing groupAccess.")
            }
            if let access = self.accessForMembers {
                if currentAccess.member != access {
                    let actionBuilder = GroupsProtoGroupChangeActionsModifyMembersAccessControlAction.builder()
                    actionBuilder.setMembersAccess(GroupAccess.protoAccess(forGroupV2Access: access))
                    actionsBuilder.setModifyMemberAccess(try actionBuilder.build())
                    didChange = true
                }
            }
            if let access = self.accessForAttributes {
                let actionBuilder = GroupsProtoGroupChangeActionsModifyAttributesAccessControlAction.builder()
                actionBuilder.setAttributesAccess(GroupAccess.protoAccess(forGroupV2Access: access))
                actionsBuilder.setModifyAttributesAccess(try actionBuilder.build())
                didChange = true
            }

            guard didChange else {
                throw GroupsV2Error.redundantChange
            }

            return try actionsBuilder.build()
        }
    }

    // GroupsV2 TODO: Ensure that we are correctly building all of the following actions:
    //
    // NOTE: This should be used after you rotate your profile key.
    //       This presumably needs to be done in a durable way.
    //    message ModifyMemberProfileKeyAction {
    //    bytes presentation = 1;
    //    }
    //
    // NOTE: This action is used to accept an invitation.
    //    message PromotePendingMemberAction {
    //    bytes presentation = 1;
    //    }
    //
    // NOTE: This won't be easy.
    //    message ModifyAvatarAction {
    //    string avatar = 1;
    //    }
    //
    // NOTE: This won't be easy.
    //    message ModifyDisappearingMessagesTimerAction {
    //    bytes timer = 1;
    //    }
}
