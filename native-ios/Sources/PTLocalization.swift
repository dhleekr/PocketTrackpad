import Foundation

func PTText(_ key:String)->String {
    NSLocalizedString(key,tableName:nil,bundle:.main,value:key,comment:"")
}

func PTFormat(_ key:String,_ arguments:CVarArg...)->String {
    String(format:PTText(key),locale:Locale.current,arguments:arguments)
}
