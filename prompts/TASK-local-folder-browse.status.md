2026-10-14 03:20 | step 0 | done | 工作树确认 /Users/boyang/code/Cove @ 08bc569；上游 LocalFolderStore.resolve(id:) 接口确认；涉及文件通读完毕 | step 1：Coordinator 三态泛化 + openLocalFolder
2026-10-14 03:25 | step 1-3 | done | Coordinator 三态泛化+openLocalFolder、BrowserViewController .local、SidebarDestination .localFolder(id:)、新增 Tests/CoveTests/LocalFolderBrowseTests.swift | make generate && make test
2026-10-14 03:28 | step 4 | done | make generate ✓；make test ✓（412 tests / 66 suites，TEST SUCCEEDED）；定向跑 LocalFolderBrowseTests 5/5 通过；xcodebuild build 零新增警告 | 任务完成，输出上报
