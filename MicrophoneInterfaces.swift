import Foundation

@MainActor protocol MicrophoneAppControlling:AnyObject {
    func prepare()async throws
    func start()async throws
    func stop()async->Bool
    func hasFinished()->Bool
}
protocol MicrophoneAudioRouting:AnyObject {
    func start()throws
    func append(_ data:Data)throws
    func stop(restore:Bool)
    func restoreInput()
    func drain()async
}

extension MicrophoneAppControlling {func hasFinished()->Bool{false}}

extension MicrophoneAudioRouting {func drain()async{}}

/// Search the focused composer before the entire window, without reading text contents.
enum MicrophoneButtonSearch {
    static func matches<Node>(roots:[Node],limit:Int=1500,hasTime:()->Bool={true},identity:((Node)->AnyHashable)?=nil,children:(Node)->[Node],isMatch:(Node)->Bool)->[Node] {
        var visited=0,seen=Set<AnyHashable>()
        for root in roots {
            var queue=[root],found=[Node]()
            while !queue.isEmpty,visited<limit,hasTime(){
                let node=queue.removeLast()
                if let key=identity?(node),!seen.insert(key).inserted{continue}
                visited+=1
                if isMatch(node){found.append(node)}
                // Composers are commonly the last sibling after a long conversation.
                queue+=children(node)
            }
            if !found.isEmpty{return found}
        }
        return []
    }
}

/// Match a named dictation control without inspecting input or conversation text.
enum MicrophoneControlIdentity {
    static func matches(_ value:String,labels:Set<String>)->Bool {
        let name=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if labels.contains(name){return true}
        // Tooltips often append the keyboard shortcut in parentheses or on a new line.
        // Never use a substring match (for example, “Dictate settings”).
        return labels.contains{label in
            name.hasPrefix(label+" (") || name.hasPrefix(label+"\n")
        }
    }
}
