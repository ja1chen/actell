# 会话与存储测试边界

本清单覆盖下列八个测试类，依据实际断言、当前生产调用链和仍受支持的数据格式分类。逐项清单列出现存方法和待整合的覆盖边界，不代表测试 target 已按分类重新组织。位于核心 target 不等于属于核心必需；核心必需也不意味着每次修改全部执行。

## 判定口径

- **核心必需**：保护当前主链的基本发送、完整保存、会话与授权隔离、停止与不重放，或防止权威数据被覆盖、伪造成空记录。
- **专项长期**：兼容迁移、Siri、后台、图片展示或索引性能等专项。非核心不等于可丢弃；功能或格式仍受支持时，其独立边界仍需覆盖，按影响域执行。
- **合并调整**：有应保留的契约，但当前用例与其他场景重叠、混合了核心与专项断言，或放错类别。先整合或拆出职责，不直接删除断言。

修改临时测试不加入上述长期清单。本类尚无足够依据将某个完整现有用例认定为纯临时验证；部分固定布局、旧文案、压力循环和观察次数断言需要缩小或转入专项，不能仅因最近为一次修复添加，就直接称为临时并删除。

## 核心契约

1. 普通消息和长草稿能完整发送、保存、重载；可选能力失败不阻塞文本主链。
2. 新草稿与正式会话身份明确，首次发送保留附件和模型选择。
3. 权威运行输出不被旧展示快照覆盖，独立会话互不串写。
4. 重复启动、迟到回调和跨会话审批不能改变错误的运行。
5. 恢复保留已知送达事实和未知结果，不继承授权、不重放动作。
6. 派生索引失败可重建，不能阻塞权威日志，也不能把缺失日志悄悄当作空会话。
7. 损坏数据保留可验证前缀和原件，不能误清未知附件；安全恢复创建独立会话。

## 分类汇总

| 测试类 | 核心必需 | 专项长期 | 合并调整 | 合计 |
| --- | ---: | ---: | ---: | ---: |
| `AgentSessionPersistenceTests` | 5 | 4 | 1 | 10 |
| `ConversationJournalTests` | 5 | 6 | 1 | 12 |
| `ConversationTests` | 8 | 6 | 1 | 15 |
| `ConversationRuntimeTests` | 7 | 1 | 2 | 10 |
| `SessionListIndexTests` | 7 | 5 | 5 | 17 |
| `SessionStorageMigrationTests` | 2 | 6 | 1 | 9 |
| `CheckpointMergeTests` | 1 | 1 | 1 | 3 |
| `SessionCommandTests` | 2 | 20 | 0 | 22 |
| **合计** | **37** | **49** | **12** | **98** |

分类数量用于核对审查是否遗漏，不是用例配额，也不是需要每次执行的数量。合并方法并不自动减少场景成本；需同时去掉重复搭建、无契约价值的循环和与改动无关的执行范围。

## 逐项结论

### AgentSessionPersistenceTests

[源码](../../ios-app/PhoneAgentTests/AgentSessionPersistenceTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testLegacyKnownToolsAreFactsIncompleteToolsArePortableAndNeverPending` | 专项长期 | 旧 UI JSONL 转换专项；保留历史工具事实及不重放断言，随该格式支持范围执行。 |
| `testStaleAppSaveCannotEraseCoreOutputAndReloadFindsNewOutput` | 核心必需 | App 旧展示快照不能覆盖运行内核已经提交的新回复，防止真实消息丢失。 |
| `testExistingToolImagesRestorePreviewWithoutAppAttachmentMetadata` | 核心必需 | 当前工具图片依赖已提交事务恢复引用和原图；缺少派生展示 metadata 不能使正常历史图片丢失。 |
| `testCorruptCommittedSuffixStillShowsVerifiedPrefix` | 核心必需 | 完整记录后缀损坏时保留可验证前缀并禁止覆盖原件，保护权威历史。 |
| `testUserRecoveryCreatesSeparateSafeSessionAndPreservesOldFiles` | 核心必需 | 用户恢复到新会话须保留原文件、复制有效附件且不继承旧运行身份和授权。 |
| `testInvalidOptionalAppMetadataUsesVerifiedIdentityAndReadableDisplay` | 核心必需 | 可选展示 metadata 损坏不能伪造会话身份或吞掉已经验证的正文。 |
| `testOriginalArchiveMigratesDirectlyIntoRuntimeContextWithoutReplayingTools` | 专项长期 | 原始归档迁移和迁移后续聊专项；属于仍受支持的兼容链路，不是每次主链回归必跑。 |
| `testInlineJournalKeepsFullDraftAndTextWithoutSessionSidecars` | 合并调整 | 完整草稿和正文重载并入 ConversationTests 的长草稿用例；精确文件集合与无 sidecar 的布局断言归存储格式专项。 |
| `testArchiveMigrationRejectsForeignAttachmentBeforePublishingSessionTree` | 专项长期 | 迁移入口的附件归属与原子发布边界；兼容功能保留期间必须保留对应专项覆盖。 |
| `testLargeOriginalArchiveUsesBoundedTransactionsAndPreservesEveryMessage` | 专项长期 | 大归档迁移容量边界专项；样本必须触发真实载荷边界，不因运行慢直接删除，也不默认执行压力场景。 |

### ConversationJournalTests

[源码](../../ios-app/PhoneAgentTests/ConversationJournalTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testAppendsOnlyChangedConversationAndMessages` | 核心必需 | 保留一条真实磁盘提交、回复重载和会话写入隔离主线；无变化保存不重复追加可在同一用例覆盖。 |
| `testMigrationWaitsForUserPreservesReferencesAndDoesNotReimportDeletedHistory` | 专项长期 | 旧归档显式迁移与删除后不重新导入的兼容契约。 |
| `testMigrationFailureAndAbandonedStagingCanBeRetried` | 专项长期 | 旧归档迁移中断和残留 staging 的恢复专项。 |
| `testMigratedPendingToolsNeverResumeAndKeepUnknownDelivery` | 专项长期 | 旧格式转换中的未知结果及不重放边界；不能因非核心而丢弃此迁移保证。 |
| `testMigrationRetryAdoptsAlreadyPublishedIdenticalDirectory` | 专项长期 | 迁移发布完成但入口状态未更新时的幂等恢复专项。 |
| `testTornTailRecoversLastCommitAndNextSaveRepairsOnlyTail` | 核心必需 | 断写尾部不能被视为已提交事实，修复不得重写前面的完整事务。 |
| `testCorruptOrFutureConversationIsPreservedWithoutBlockingHealthyFiles` | 核心必需 | 损坏会话不得被覆盖，也不能扩大成所有健康会话不可保存。 |
| `testEmptyLegacyArchiveMigratesOnceAndFutureArchiveIsNotOverwritten` | 专项长期 | 空旧归档和未来版本兼容边界，可表驱动，按兼容域执行。 |
| `testFutureDirectoryFormatDoesNotFallBackToLegacyArchive` | 专项长期 | 版本识别专项；未知新格式不能回退导入旧来源并覆盖现有数据。 |
| `testFailedAppendKeepsDirtyConversationForRetry` | 核心必需 | 写入失败后保留待保存数据，条件恢复后可重试，不能永久丢失或冻结会话。 |
| `testAppendOnlyHistoryAndMessageRemovalPreserveLatestState` | 合并调整 | 保留删除展示项与最终状态重载断言，并入日志提交用例；多次大文本循环移到存储压力专项，不能把重复次数当作新增契约。 |
| `testDeletingOneConversationAndClearingDoNotRestoreFilesOnRelaunch` | 核心必需 | 正常删除、清空必须持久生效，不能在重启后复活，也不能删除其他会话。 |

### ConversationTests

[源码](../../ios-app/PhoneAgentTests/ConversationTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testLongPreparedTaskAndEditedDraftPersistWithoutTruncation` | 核心必需 | 完整长草稿保存和重载是通用数据完整性契约；保留这一主线，Siri prepare 的专属断言应拆归 Siri 专项。 |
| `testTurnSummaryGroupsWholeRunsAndCountsOnlyNonemptyThoughtsAndToolCalls` | 专项长期 | 折叠、计数和展示摘要属于展示专项；精确中文文案不能定义存储核心契约。 |
| `testUnsentDraftStaysOutOfHistoryAndEveryArchiveWrite` | 核心必需 | 未发送的新会话草稿不得进入已提交历史，离开可丢弃；不能误删既有会话。 |
| `testFirstMessagePromotesDraftWithSameIdentityAndAttachments` | 核心必需 | 首条发送保持会话、服务商和附件身份并完成持久化，不能丢附件或重复创建会话。 |
| `testEmptyToolArgumentsAreHiddenWithoutHidingZeroOrFalse` | 专项长期 | 工具参数展示格式专项，不影响事务提交或发送授权。 |
| `testPersistAndRestoreInterruptsUnfinishedToolsWithoutResuming` | 核心必需 | 重启后未完成操作须收敛到中断状态，不能自动恢复旧授权或执行。 |
| `testBackgroundCompletionPublishesAccumulatedMessagesAtActiveScene` | 专项长期 | 前后台展示刷新专项；在后台或展示生命周期变化时执行。 |
| `testBackgroundStreamingPersistsWithoutPublishingHiddenConversationChanges` | 专项长期 | 后台流式落盘与刷新合并专项；固定回调次数和大量重复输入不是每次存储回归必需。 |
| `testRecoveryUsesDeliveryJournalInsteadOfCancellingAcknowledgedDrag` | 核心必需 | 区分已确认、结果未知、尚未发送和拒绝状态，恢复不能篡改送达事实或重放动作。 |
| `testRecoveryLeavesExistingNoticesAndHistoryOrderUnchanged` | 合并调整 | 恢复不能修改既有用户文本和顺序值得保留；并入恢复一致性场景，旧通知原文和旧归档 fixture 留在兼容专项。 |
| `testLateEventsCannotAffectAnotherConversationOrLaterRun` | 核心必需 | 旧运行的回调不得串写其他会话或结束新运行。 |
| `testDuplicateBeginDoesNotAppendSecondUserMessage` | 核心必需 | 重复启动不能追加第二条用户消息，无效会话不能创建运行。 |
| `testUnreadableHistoryIsNeverOverwritten` | 专项长期 | 此用例只构造旧 conversations-v1.json；保留在兼容域，当前格式损坏保护由日志与索引用例覆盖。 |
| `testLegacyMigrationRunsOnlyOnceAndPreservesDrafts` | 专项长期 | 更早 TaskRecord 来源转换专项，受支持期间保留，不等同于普通会话创建。 |
| `testQueuedToolStartCannotUndoApprovalState` | 核心必需 | 迟到的开始事件不能覆盖当前等待授权状态，避免正常审批流程失效。 |

### ConversationRuntimeTests

[源码](../../ios-app/PhoneAgentTests/ConversationTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testUnavailableWorkspaceDisablesOnlyFileTools` | 核心必需 | 工作区失效只能影响文件能力，不能让普通聊天无法完成；保护实际发送主链的降级行为。 |
| `testModelCapabilityDegradationStillCompletesTextChat` | 核心必需 | 不支持工具或图片的模型仍能进行文本聊天；未知能力不能被误判为不可用。 |
| `testToolReceiptsAreSavedBeforeNextModelRequest` | 核心必需 | 工具事实必须先持久化再进入下一次推理，防止上下文与执行事实不一致。 |
| `testDemoUsesRealAgentLoopAndStructuredToolEvents` | 核心必需 | 保留一条真实 Agent、审批、工具和最终回复的集成主线；demo 是夹具，固定演示文案和调用序列不是额外核心契约。 |
| `testToolFailureReachesNextModelTurnWithoutDuplicateNotice` | 核心必需 | 工具失败必须传给下一次模型请求并允许正常回答，不能吞错、误报成功或阻断整轮。 |
| `testEmptyReplyAfterToolFailureDoesNotReuseNarrationOrAddNotice` | 合并调整 | 并入工具失败回复矩阵，保留空最终回复不能被旧叙述冒充的断言，不单独复制整套运行夹具。 |
| `testConcurrentSessionsKeepApprovalsAndCancelIndependently` | 核心必需 | 跨会话审批、停止和真实工具执行必须独立，错误会话不能批准或取消其他运行。 |
| `testParallelStoreCallbacksRemainScopedAfterOneRunEnds` | 合并调整 | 与 ConversationTests 的迟到事件用例合并成同会话新轮次、跨会话和并行运行矩阵；真实审批集成测试单独保留。 |
| `testBackgroundCancellationFencesLateEvents` | 专项长期 | 后台切换导致取消的生命周期专项；通用迟到回调隔离已有核心覆盖。 |
| `testLiveSendRequiresExplicitConsentBeforeReadingKeysOrRunning` | 核心必需 | 没有本轮发送授权时不能读取密钥或开始模型任务，普通点击发送已提供授权。 |

### SessionListIndexTests

[源码](../../ios-app/PhoneAgentTests/SessionListIndexTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testIndexIsBoundedAndExcludesFullDraftsAttachmentsAndMessages` | 专项长期 | 紧凑缓存结构、预览长度和避免重复存储属于索引布局及性能专项；完整正文重载已有核心用例。 |
| `testValidIndexLoadsLazilyAndDetectsEngineHistoryChanges` | 核心必需 | 运行内核新增权威回复后，列表和按需读取必须看到新事实；精确懒加载策略可降为索引专项。 |
| `testMissingCorruptFutureDuplicateAndInvalidPathIndexesRebuildWithoutMigration` | 核心必需 | 索引缺失、损坏或路径无效不得丢失权威会话或误触发迁移；保留一条容错矩阵。 |
| `testUpdatingAndDeletingRefreshIndexWithoutRewritingOtherSessions` | 合并调整 | 更新预览、删除及不改其他会话并入基础日志与索引重建用例，避免重复建立同一磁盘场景。 |
| `testInterruptedIndexPublicationRebuildsCommittedCreatesAndDeletes` | 核心必需 | 索引发布中断后，权威会话的创建和删除必须能正确重建。 |
| `testFailedIndexPublicationDoesNotBlockAuthoritativeChanges` | 核心必需 | 派生缓存写失败不能撤销真实日志写入，也不能阻止正常保存和删除。 |
| `testLazyCorruptionDiscoveryPreservesFileAndDisablesAttachmentCleanup` | 合并调整 | 与构造后损坏用例形成完整损坏位置矩阵，保留全文件损坏与后缀损坏两种边界，不复制独立公共夹具。 |
| `testCorruptionAfterLazyConstructionReturnsPrefixAndDisablesAttachmentCleanup` | 核心必需 | 构造完成后发生的新损坏仍需在读取时识别；不能因先前缓存健康而误清未知附件。 |
| `testDeleteRechecksLazyAndPreviouslyLoadedHistoryBeforeRemovingSession` | 核心必需 | 删除前必须核实当前权威文件，防止加载后出现的损坏导致原历史和未知资源被破坏。 |
| `testDeleteDiscoveryAlsoDisablesAttachmentCleanupInConversationStore` | 合并调整 | 将 Store 入口传播 warning 和清理状态的断言并入删除前核验矩阵；不能仅保留 Journal 层断言而漏掉对外状态。 |
| `testSiriIndexRetainsCommandRoutingButLoadsFullDraftBeforeUse` | 专项长期 | Siri 路由和完整任务加载专项，普通聊天入口不依赖此命令路由。 |
| `testOneStaleOrMalformedEntryRebuildsOnlyThatConversation` | 专项长期 | 逐行增量重建与不加载其他健康历史属于索引性能策略；按索引实现改动执行。 |
| `testScalarNullAndMalformedCacheRowsCannotInvalidateHealthyLazyEntries` | 专项长期 | 异常缓存行的增量容错专项；不丢正常会话的通用保证由核心索引矩阵覆盖。 |
| `testStaleExistingStateDetectsCommittedCreateAndDeleteWithoutScanningUnchangedHistory` | 合并调整 | 与索引发布中断用例合并为缓存缺失和旧缓存仍存在两种情况；不扫描其他历史归性能专项。 |
| `testMissingCommittedHistoryNeverBecomesEmptyOnReopenOrOldStateUpgrade` | 核心必需 | 权威日志缺失不能悄悄变成一个可覆盖的空会话，必须暴露缺口并保留恢复可能。 |
| `testOldDerivedStateRebuildsOnceAndRetiresOnlySessionSummary` | 专项长期 | 旧缓存版本及旧派生 metadata 清理的兼容专项。 |
| `testUpdatingLazySiriMetadataPreservesFullDraftAndAttachmentReferences` | 合并调整 | 通用的惰性 metadata 更新不能丢完整草稿与附件，应并入核心草稿用例；Siri commandID 归入口专项。 |

### SessionStorageMigrationTests

[源码](../../ios-app/PhoneAgentTests/SessionStorageMigrationTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testSeparateLegacyRootMigratesToDocumentsWithoutMovingOriginalsOrPromptingAgain` | 专项长期 | 旧数据根目录迁移和不重新提示专项，按兼容版本及迁移实现改动执行。 |
| `testNewInstallDoesNotNeedLegacyDirectoryOrMigration` | 核心必需 | 没有旧数据的新安装必须能直接初始化，不因旧目录不存在而阻塞使用；精确目录集合属于布局专项。 |
| `testFailedCrossDirectoryMigrationDoesNotPublishStateBeforeRetry` | 专项长期 | 跨目录迁移的原子发布与失败重试专项。 |
| `testOneMigrationGroupsRootAndScopedCheckpointsWithHistoryAndAttachments` | 专项长期 | 旧根检查点、会话检查点、历史和附件的统一归属转换专项。 |
| `testCheckpointOnlyMigrationAndInterruptedCaseRenamePreserveOrphanedRuns` | 专项长期 | 仅有检查点及大小写目录更名中断的兼容边界，不属于普通会话启动。 |
| `testCorruptCheckpointBlocksPublishAndCanRetryWithoutChangingOriginals` | 专项长期 | 迁移源检查点损坏时不发布半成品，保留原件并允许修复后重试；迁移支持期间必须保留。 |
| `testCheckpointConversationMismatchIsNeverAssignedToAnotherSession` | 专项长期 | 旧检查点会话归属不匹配的迁移安全边界，不可因非核心而删除对应保护。 |
| `testStateProjectionLoadsOnlyRequestedHistoryAndRebuildsChangedLog` | 合并调整 | 与 SessionListIndexTests 的日志变化、缓存失效、惰性保存场景重复；合并到索引域而非继续放在迁移类。 |
| `testDatedDirectoryDoesNotChangeAfterUpdatesAndDraftAttachmentsStayTogether` | 核心必需 | 实际文件从草稿转为正式会话后仍保持身份和附件归属，更新不能另建目录丢失资源，正常删除可清理所属资源。 |

### CheckpointMergeTests

[源码](../../ios-app/PhoneAgentTests/ProjectTodoTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testBothFilesRecoverDistinctUnknownActionsAndNeverRestoreAuthorization` | 专项长期 | 同时存在旧 USB 与当前检查点文件的兼容专项；仍须保留未知动作及不继承授权的断言。 |
| `testSameRunDeduplicatesButRetainsBothTransactionsAndUnknownWins` | 核心必需 | 恢复合并不能丢动作账本，也不能把不确定送达改成确定成功；属于当前执行恢复的不变量。 |
| `testNoDefaultInactivityBudgetButSystemLossStillPauses` | 合并调整 | 不属于会话存储，应移到生命周期类别继续审查；与已有超时配置和失去执行能力的用例整合，不能在此重复扩张。 |

### SessionCommandTests

[源码](../../ios-app/PhoneAgentTests/SessionCommandTests.swift)

| 用例 | 分类 | 依据与处理建议 |
| --- | --- | --- |
| `testLongTaskStartsAndPreservesFullUserMessage` | 核心必需 | 实际普通 send 入口必须接受并完整保留长文本；应归通用发送测试，而非让名称将其误归为 Siri。 |
| `testRejectedStartReportsItsSpecificReason` | 专项长期 | SessionCommandService 将真实启动原因传给 Siri/命令入口，属于入口专项。 |
| `testSendWhileInactiveReportsForegroundReasonWithoutStarting` | 核心必需 | 普通 send 的前台条件和失败可见性；保留不启动和具体原因断言，避免绑定精确中文措辞。 |
| `testDirectExecuteInitializesDefaultProviderWithoutOpeningConversation` | 专项长期 | Siri 直接执行时为新会话绑定默认服务商的入口专项。 |
| `testBackgroundExecuteCreatesIndependentSessionWithoutForegroundOrReplay` | 专项长期 | Siri 后台执行、保活和独立会话专项，不属于普通聊天的默认路径。 |
| `testWarmIdleBackgroundRequiresForegroundUntilPlaybackIsActuallyActive` | 专项长期 | Siri 前台请求与真实后台播放可用性的交接专项。 |
| `testBackgroundExecuteWaitsForUnlockAndDoesNotCreateRun` | 专项长期 | Siri 保护数据不可用时延后执行的专项。 |
| `testInactiveHandoffStartsOnlyOnceWhenActiveAndDoesNotSurviveRelaunch` | 专项长期 | Siri 进程内交接队列的幂等与不跨重启执行专项。 |
| `testDirectExecuteStartsOnceAndDoesNotReplayAfterRestore` | 专项长期 | 命令 ID 的持久幂等专项，支持该入口期间保留不重放保证。 |
| `testDirectExecuteFailureDoesNotReportStarted` | 专项长期 | Siri 启动失败不能声称已开始，保留在入口失败矩阵。 |
| `testPrepareValidatesBeforeSavingAndDoesNotRun` | 专项长期 | Siri prepare 的空输入、长输入和仅保存不执行专项，可表驱动。 |
| `testColdLaunchAndRetryRetainIdentityButIdenticalNewRequestIsDistinct` | 专项长期 | Siri 命令身份与相同文本的新请求区分专项。 |
| `testBusyOpenAllowsNavigationWithoutCancellingAnotherRun` | 专项长期 | Siri 待确认任务导航不能取消另一个运行，属于入口导航专项。 |
| `testCapturedCancelCannotStopLaterRunInSameSessionOrAnotherSession` | 专项长期 | Siri 捕获的取消命令须限定原运行，不能取消新任务；保留在入口授权边界。 |
| `testCancelCapturedWhenIdleNeverStopsFutureRun` | 专项长期 | Siri 空闲时捕获取消不得作用于未来任务，可与同域取消身份矩阵整合。 |
| `testDismissedDraftDoesNotRouteAfterRestartOrRetry` | 专项长期 | Siri 已取消草稿不能在重启或重试时重新路由。 |
| `testSubmittedDraftRecordsRunAndNeverResumesOnColdLaunch` | 专项长期 | Siri 提交记录与运行绑定，冷启动不自动续跑的专项。 |
| `testCorruptArchiveAndFailedWriteNeverClaimDraftSaved` | 专项长期 | Siri 保存失败不得返回成功；旧归档损坏部分还可复用兼容夹具。 |
| `testStatusNeverIncludesTaskTextAndTracksRunner` | 专项长期 | Siri 状态反馈与任务文本隐私专项。 |
| `testAuthenticationAndForegroundPolicy` | 专项长期 | App Intent 类型、认证和运行模式声明专项，不是会话存储契约。 |
| `testCancelledIntentDoesNotCreateDraft` | 专项长期 | 取消 Siri Intent 不创建草稿的入口生命周期专项。 |
| `testConfirmedSiriDraftUsesExistingApprovalAndScopedStop` | 专项长期 | Siri 提交后沿用现有审批和限定停止的集成专项，不重复计为通用发送核心。 |

## 整合顺序

- 将 `SessionCommandTests` 中两个普通 send 用例归回通用发送，其余 Siri 专项单独管理；索引中的 Siri 路由也随同归域。
- 将旧归档、旧 UI JSONL、旧检查点和旧目录转换归入兼容域。保留仍受支持的原子发布、归属与不重放边界；退役须先确认不再支持相应来源，不能因测试慢直接移除。
- 日志与索引容错保留最小代表性矩阵，整合缺失缓存、旧缓存、损坏行、日志缺失和删除时新发现损坏，避免同一公共初始化重复扩张。精确懒加载策略和压力输入留在专项。
- 完整长草稿、正文和附件引用的重载只保留必要代表场景；更新元数据造成数据丢失的独立入口不能因合并而漏掉。
- `CheckpointMergeTests` 中的无默认超时与后台失效暂停归到生命周期类别继续审查，不在会话存储域重复保留。

执行这些建议前应分别明确迁移、合并或删除的具体范围；本清单本身不改变现有用例实现或默认脚本的实际选择。
