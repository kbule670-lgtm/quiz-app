// 内置示例题：让她先跑通"导入→刷题→错题本"全流程，之后删掉换成她的真题
enum SampleBank {
    static let questions: [QuestionDTO] = [
        QuestionDTO(
            stem: "示例·化学：下列物质中，属于电解质的是？",
            options: ["铜", "蔗糖", "NaCl 溶液", "熔融 NaCl"],
            answerIndex: 3,
            explanation: "电解质必须是化合物；熔融 NaCl 能导电，所以选 D。"
        ),
        QuestionDTO(
            stem: "示例·物理：下列哪个物理量的单位是 kg·m/s？",
            options: ["功", "动量", "功率", "压强"],
            answerIndex: 1,
            explanation: "动量 p = mv，单位 kg·m/s。"
        ),
        QuestionDTO(
            stem: "示例·数学：函数 f(x) = 2x + 1，则 f(3) = ？",
            options: ["5", "6", "7", "8"],
            answerIndex: 2,
            explanation: "f(3) = 2×3 + 1 = 7。"
        ),
        QuestionDTO(
            stem: "示例·英语：sophisticated 的意思是？",
            options: ["简单的", "复杂的；精密的", "便宜的", "快速的"],
            answerIndex: 1,
            explanation: "sophisticated = 复杂的、精密的，老练的。"
        ),
        QuestionDTO(
            stem: "示例·生物：光合作用的主要场所是？",
            options: ["线粒体", "叶绿体", "细胞核", "核糖体"],
            answerIndex: 1,
            explanation: "叶绿体是光合作用的场所。"
        ),
        QuestionDTO(
            stem: "示例·多选：下列说法正确的是？（多选，试试勾选和提交）",
            options: ["水是化合物", "氧气是单质", "盐酸是纯净物", "空气是混合物"],
            answerIndex: 0,
            explanation: "盐酸是 HCl 的水溶液，是混合物；其余都对，答案 A、B、D。",
            isMulti: true,
            answerIndices: [0, 1, 3]
        ),
        QuestionDTO(
            stem: "示例·判断：地球是太阳系中唯一有生命的已知行星。（判断题，只有两个选项）",
            options: ["正确", "错误"],
            answerIndex: 0,
            explanation: ""
        ),
    ]
}
