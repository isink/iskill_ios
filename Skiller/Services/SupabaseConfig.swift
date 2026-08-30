import Foundation
import Supabase

enum SupabaseConfig {
    static let url = URL(string: "https://gphynosbfjcyexhkgctf.supabase.co")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdwaHlub3NiZmpjeWV4aGtnY3RmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYxNzg3ODQsImV4cCI6MjA5MTc1NDc4NH0.0QtUhSnGn0wPwVjyjkPdCIaebIaCvvcVw9AAjtEY9_8"
    static let authOptions = SupabaseClientOptions.AuthOptions(autoRefreshToken: false)
}

let supabase = SupabaseClient(
    supabaseURL: SupabaseConfig.url,
    supabaseKey: SupabaseConfig.anonKey,
    options: SupabaseClientOptions(auth: SupabaseConfig.authOptions)
)
