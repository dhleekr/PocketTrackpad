import Foundation

@MainActor protocol MicrophoneAppControlling:AnyObject {
    func prepare()throws
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
    static func matches<Node>(roots:[Node],limit:Int=1500,hasTime:()->Bool={true},children:(Node)->[Node],isMatch:(Node)->Bool)->[Node] {
        var visited=0
        for root in roots {
            var queue=[root],index=0,found=[Node]()
            while index<queue.count,visited<limit,hasTime(){
                let node=queue[index];index+=1;visited+=1
                if isMatch(node){found.append(node)}
                queue+=children(node)
            }
            if !found.isEmpty{return found}
        }
        return []
    }
}
