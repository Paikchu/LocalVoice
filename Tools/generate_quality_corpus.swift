import Foundation

struct QualityCase: Codable {
    let id: String
    let transcript: String
    let mode: String
    let expectedIntent: String
    let requiredFacts: [String]
    let semanticGroups: [[String]]
    let requiresEmailStructure: Bool
}

let names = ["李明", "王芳", "陈晨", "赵敏", "Alex"]
let projects = ["LocalVoice", "Atlas", "Nova", "Orion", "Pixel"]
let deadlines = ["周五", "6 月 15 日", "明天下午", "本周三", "下周一"]
let actions = ["反馈", "确认", "测试", "回复", "审核"]
let nameAlternatives = [
    "李明": ["李明", "Li Ming"],
    "王芳": ["王芳", "Wang Fang"],
    "陈晨": ["陈晨", "Chen Chen"],
    "赵敏": ["赵敏", "Zhao Min"],
    "Alex": ["Alex"]
]
let deadlineAlternatives = [
    "周五": ["周五", "Friday"],
    "6 月 15 日": ["6 月 15 日", "June 15", "15 June"],
    "明天下午": ["明天下午", "tomorrow afternoon"],
    "本周三": ["本周三", "this Wednesday"],
    "下周一": ["下周一", "next Monday"]
]
let actionAlternatives = [
    "反馈": ["反馈", "reply", "provide feedback"],
    "确认": ["确认", "confirm"],
    "测试": ["测试", "test"],
    "回复": ["回复", "reply", "respond"],
    "审核": ["审核", "review"]
]

var cases: [QualityCase] = []
for index in 0..<100 {
    let name = names[index % names.count]
    let project = projects[index % projects.count]
    let deadline = deadlines[index % deadlines.count]
    let action = actions[index % actions.count]
    let code = "LV-\(2000 + index)"
    let isEnglish = index % 5 == 0
    cases.append(
        QualityCase(
            id: String(format: "email-%03d", index + 1),
            transcript: "嗯，帮我给\(name)发一封邮件，说\(project)第一版已经完成，编号\(code)，请他在\(deadline)前\(action)，谢谢",
            mode: isEnglish ? "english" : "dictation",
            expectedIntent: "composeEmail",
            requiredFacts: [name, project, code],
            semanticGroups: [
                ["第一版已经完成", "第一版已完成", "first version is complete"],
                deadlineAlternatives[deadline]!,
                actionAlternatives[action]!
            ],
            requiresEmailStructure: true
        )
    )
}

let plainTemplates: [(String, [[String]])] = [
    ("我收到一封邮件，里面提到了{project}的测试安排", [["收到一封邮件", "received an email"], ["测试安排", "test schedule", "testing schedule", "test scheduling"]]),
    ("不用发邮件，记一下{name}会在{deadline}前{action}", []),
    ("那个今天下午我们开始测试{project}，编号是{code}", [["今天下午", "this afternoon", "today afternoon", "today in the afternoon"], ["开始测试", "start testing"]]),
    ("请记录会议结论，{project}第一版已经完成", [["会议结论", "meeting conclusion"], ["第一版已经完成", "第一版已完成", "first version is complete", "first version is completed"]]),
    ("邮件这个词只是在笔记里出现，不是发送命令", [["不是发送命令", "not a send command", "not as a send command"], ["笔记", "note"]]),
    ("第一点确认需求第二点完成开发第三点安排测试", [["1. 确认需求"], ["2. 完成开发"], ["3. 安排测试"]]),
    ("今天完成开发逗号明天开始测试句号是否按计划发布问号", [["今天完成开发"], ["明天开始测试"], ["是否按计划发布"]]),
    ("这是{project}第一版，计划第二季度发布，并交给第三方测试", [["第一版", "first version"], ["第二季度", "second quarter"], ["第三方", "third party"]]),
    ("请记录{project}的地址https://local.voice/{code}，编号{code}，时间15:30，预算¥1200.50", [["地址", "address"], ["时间", "time"], ["预算", "budget"]]),
    ("逗号是中文标点，这个字段叫句号状态", [["逗号", "comma"], ["句号状态", "period status"]])
]

for index in 0..<100 {
    let name = names[index % names.count]
    let project = projects[index % projects.count]
    let deadline = deadlines[index % deadlines.count]
    let action = actions[index % actions.count]
    let code = "LV-\(3000 + index)"
    let templateIndex = index % plainTemplates.count
    let template = plainTemplates[templateIndex]
    func expand(_ value: String) -> String {
        value
            .replacingOccurrences(of: "{name}", with: name)
            .replacingOccurrences(of: "{project}", with: project)
            .replacingOccurrences(of: "{deadline}", with: deadline)
            .replacingOccurrences(of: "{action}", with: action)
            .replacingOccurrences(of: "{code}", with: code)
    }
    let transcript = expand(template.0)
    var requiredFacts: [String] = []
    if transcript.contains(project) { requiredFacts.append(project) }
    let isEnglish = index % 6 == 0
    if transcript.contains(name), !isEnglish { requiredFacts.append(name) }
    if transcript.contains(code) { requiredFacts.append(code) }
    var semanticGroups = template.1.map { $0.map(expand) }
    if transcript.contains(deadline) {
        semanticGroups.append(deadlineAlternatives[deadline]!)
    }
    if transcript.contains(action) {
        semanticGroups.append(actionAlternatives[action]!)
    }
    if transcript.contains(name), isEnglish {
        semanticGroups.append(nameAlternatives[name]!)
    }
    cases.append(
        QualityCase(
            id: String(format: "plain-%03d", index + 1),
            transcript: transcript,
            mode: isEnglish ? "english" : "dictation",
            expectedIntent: "plainText",
            requiredFacts: requiredFacts,
            semanticGroups: semanticGroups,
            requiresEmailStructure: false
        )
    )
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(cases).write(to: output, options: .atomic)
print("Generated \(cases.count) cases at \(output.path)")
