import SwiftUI
import AVFoundation
import MediaPlayer
import CoreGraphics
import WatchKit

// MARK: - App Entry Point
@main
struct WatchMusicApp: App {
    // This adaptor ensures that the ExtensionDelegate class is instantiated
    // and set as the delegate for the WKApplication singleton.
    @WKApplicationDelegateAdaptor(ExtensionDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            // We inject the delegate into the environment here, making it accessible
            // to all child views in a safe, SwiftUI-native way.
            ContentView()
                .environmentObject(delegate)
        }
    }
}

// MARK: - App Delegate
// Conforms to ObservableObject so it can be used in the environment.
class ExtensionDelegate: NSObject, WKApplicationDelegate, ObservableObject, URLSessionDownloadDelegate {
    
    // A lazy var ensures the session is created only once, with self as the delegate.
    lazy var backgroundURLSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.yourapp.backgrounddownloader")
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    
    // A completion handler to call when all background tasks are finished.
    var backgroundTaskCompletionHandler: (() -> Void)? = nil
    
    // This is called when the app launches
    func applicationDidFinishLaunching() {
        // By the time this method is called, the delegate is fully initialized and set.
        print("Application Did Finish Launching. Delegate is set.")
    }

    // This is called when background downloads are complete.
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlSessionTask = task as? WKURLSessionRefreshBackgroundTask {
                let _ = self.backgroundURLSession
                print("App woken for background task. Session delegate is set.")
                self.backgroundTaskCompletionHandler = {
                    urlSessionTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
    
    // MARK: - URLSessionDownloadDelegate
    
    // This delegate method is called when a file has finished downloading.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // We now reconstruct the destination path from the relative path stored in the task description.
        guard let relativePath = downloadTask.taskDescription else {
            print("Error: Could not get relative path from task description.")
            return
        }

        let fileManager = FileManager.default
        
        do {
            let documentsURL = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let destinationPath = documentsURL.appendingPathComponent(relativePath)
            let directoryURL = destinationPath.deletingLastPathComponent()
            
            // Ensure the destination directory exists.
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            
            // If a file already exists at the destination, remove it.
            if fileManager.fileExists(atPath: destinationPath.path) {
                try fileManager.removeItem(at: destinationPath)
            }
            
            // Move the downloaded file from the temporary location to its final destination.
            try fileManager.moveItem(at: location, to: destinationPath)
            print("Successfully moved downloaded file to: \(destinationPath.path)")
            
        } catch {
            print("Error moving downloaded file: \(error)")
        }
    }

    // This delegate method is called when all events for a background session have been delivered.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundTaskCompletionHandler?()
            self.backgroundTaskCompletionHandler = nil
        }
    }
    
    // This delegate method is called when a task completes, either with an error or successfully.
    // It is crucial for debugging background download failures.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("Background download task failed: \(task.taskDescription ?? "No description") - Error: \(error.localizedDescription)")
        } else {
            // This is logged for a successfully completed task, right after didFinishDownloadingTo has been called.
            print("Background download task finished successfully: \(task.taskDescription ?? "No description")")
        }
    }
}

// MARK: - Navigation
enum NavigationDestination: Hashable {
    case artist(Artist)
    case album(Album)
}

enum Tab {
    case player, library, playlists
}

class ViewRouter: ObservableObject {
    @Published var currentTab: Tab = .library
    @Published var libraryPath = [NavigationDestination]()

    func navigateTo(artist: Artist, album: Album?) {
        self.currentTab = .library
        DispatchQueue.main.async {
            self.libraryPath.removeAll()
            self.libraryPath.append(.artist(artist))
            if let album = album {
                self.libraryPath.append(.album(album))
            }
        }
    }
}

// MARK: - Data Models
struct Song: Identifiable, Hashable, Codable {
    var id = UUID()
    let title: String
    let artist: String
    let album: String
    let relativePath: String

    var path: URL {
        do {
            let documentsURL = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            // appendingPathComponent correctly handles subdirectories from the relativePath string.
            return documentsURL.appendingPathComponent(relativePath)
        } catch {
            print("Could not find documents directory: \(error)")
            return URL(fileURLWithPath: "")
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, relativePath
    }
}

struct Album: Identifiable, Hashable, Codable {
    var id = UUID()
    let name: String
    var songs: [Song]
}

struct Artist: Identifiable, Hashable, Codable {
    var id = UUID()
    let name: String
    var albums: [Album]
}

struct Playlist: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var songs: [Song]
}

// MARK: - Networking Error
enum NetworkError: Error, LocalizedError {
    case invalidURL
    case downloadFailed(String)
    case decodingFailed
    case requestFailed(Error)
    case generalError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The server URL is invalid."
        case .downloadFailed(let message): return message
        case .decodingFailed: return "Failed to decode server response."
        case .requestFailed(let error): return "Request failed: \(error.localizedDescription)"
        case .generalError(let message): return message
        }
    }
}

// MARK: - Repeat Mode Enum
enum RepeatMode {
    case none, one, all
}


// MARK: - Playlist Manager
class PlaylistManager: ObservableObject {
    @Published var playlists: [Playlist] = [] {
        didSet {
            savePlaylists()
        }
    }
    private let playlistsKey = "userPlaylists"

    init() {
        loadPlaylists()
    }

    func createPlaylist(name: String) {
        let newPlaylist = Playlist(name: name, songs: [])
        playlists.append(newPlaylist)
    }

    func addSong(_ song: Song, to playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if !playlists[index].songs.contains(where: { $0.id == song.id }) {
            playlists[index].songs.append(song)
        }
    }
    
    func removeSong(_ song: Song, from playlistID: UUID) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[playlistIndex].songs.removeAll { $0.id == song.id }
    }

    func removeSongs(at offsets: IndexSet, from playlistID: UUID) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[playlistIndex].songs.remove(atOffsets: offsets)
    }
    
    private func savePlaylists() {
        if let encoded = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(encoded, forKey: playlistsKey)
        }
    }

    private func loadPlaylists() {
        if let savedPlaylists = UserDefaults.standard.data(forKey: playlistsKey) {
            if let decodedPlaylists = try? JSONDecoder().decode([Playlist].self, from: savedPlaylists) {
                self.playlists = decodedPlaylists
                return
            }
        }
        self.playlists = []
    }
}

// MARK: - String Extension
extension String {
    func removingTrackNumber() -> String {
        let pattern = "^\\d+\\s*([.-]|\\s-)?\\s*"
        return self.replacingOccurrences(of: pattern, with: "", options: .regularExpression, range: nil)
    }
}

// MARK: - Music Library Manager
class MusicLibraryManager: NSObject, ObservableObject {
    @Published var artists = [Artist]()
    @Published var isLoading = false
    @Published var loadingMessage = ""
    @Published var downloadError: String?

    private let libraryStorageKey = "musicLibrary"
    
    private struct AlbumEntry: Decodable {
        let name: String
        let artist: String
        let songs: [Song]
    }

    override init() {
        super.init()
        loadLibraryFromStorage()
    }

    func loadLibraryFromStorage() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: libraryStorageKey),
           let decodedArtists = try? decoder.decode([Artist].self, from: data) {
            self.artists = decodedArtists
            print("Successfully loaded library from storage.")
        } else {
            print("No library found in storage. Ready for import.")
        }
    }

    private func saveLibraryToStorage(artists: [Artist]) {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(artists) {
            UserDefaults.standard.set(encoded, forKey: libraryStorageKey)
            print("Library saved to storage.")
        }
    }

    private func deleteAllLocalFiles() {
        let fileManager = FileManager.default
        do {
            let documentsURL = try fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            if fileManager.fileExists(atPath: documentsURL.path) {
                let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil, options: [])
                for fileURL in fileURLs {
                    try fileManager.removeItem(at: fileURL)
                }
                print("Successfully deleted all local music files.")
            }
        } catch {
            print("Error deleting local music files: \(error)")
        }
    }

    @MainActor
    func deleteLibrary() {
        isLoading = true
        loadingMessage = "Deleting Library..."

        Task {
            self.artists = []
            UserDefaults.standard.removeObject(forKey: libraryStorageKey)
            print("Removed library metadata from UserDefaults.")
            deleteAllLocalFiles()
            
            isLoading = false
            loadingMessage = ""
        }
    }

    // MARK: - Download Logic
    @MainActor
    func startBackgroundDownload(from ipAddress: String, delegate: ExtensionDelegate) {
        isLoading = true
        downloadError = nil
        loadingMessage = "Clearing old library..."
        
        self.artists = []
        saveLibraryToStorage(artists: [])
        deleteAllLocalFiles()
        print("Cleared old library and deleted local files.")
        
        Task {
            do {
                loadingMessage = "Fetching library index..."
                print("Step 1: Fetching index.json from http://\(ipAddress)/index.json")

                guard let url = URL(string: "http://\(ipAddress)/index.json") else {
                    throw NetworkError.invalidURL
                }
                
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    print("Error: Invalid response or status code for index.json. Status: \(statusCode)")
                    throw NetworkError.downloadFailed("Could not fetch library index. Server status: \(statusCode)")
                }

                print("Step 2: Decoding index.json")
                let decoder = JSONDecoder()
                let albumEntries = try decoder.decode([AlbumEntry].self, from: data)
                let baseURL = url.deletingLastPathComponent()

                print("Step 3: Processing and saving new library metadata.")
                var finalArtists = [Artist]()
                var artistDict = [String: [Album]]()
                for entry in albumEntries {
                    let newAlbum = Album(name: entry.name, songs: entry.songs)
                    artistDict[entry.artist, default: []].append(newAlbum)
                }
                finalArtists = artistDict.map { artistName, albums in
                    Artist(name: artistName, albums: albums.sorted { $0.name < $1.name })
                }.sorted { $0.name < $1.name }

                self.artists = finalArtists
                saveLibraryToStorage(artists: finalArtists)

                print("Step 4: Using passed-in app delegate.")
                let session = delegate.backgroundURLSession

                let allSongs = finalArtists.flatMap({ $0.albums.flatMap({ $0.songs }) })
                print("Step 5: Starting background downloads for \(allSongs.count) songs.")
                for song in allSongs {
                    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
                        print("Error: Could not create URLComponents for song: \(song.title)")
                        continue
                    }
                    let encodedPath = song.relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
                    components.percentEncodedPath = "/" + encodedPath
                    
                    guard let songDownloadURL = components.url else {
                        print("Error: Could not create a valid download URL for song: \(song.title) with path: \(components.percentEncodedPath)")
                        continue
                    }

                    let downloadTask = session.downloadTask(with: songDownloadURL)
                    downloadTask.taskDescription = song.relativePath
                    downloadTask.resume()
                }

                print("Step 6: All download tasks created successfully.")
                loadingMessage = "Downloads started in background. You can leave the app."
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    self.isLoading = false
                }

            } catch {
                let errorMessage = "Error: \(error.localizedDescription)"
                print("ERROR in startBackgroundDownload: \(errorMessage)")
                self.isLoading = false
                self.downloadError = errorMessage
            }
        }
    }
}


// MARK: - Music Player Manager
class MusicPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentSong: Song?
    @Published var volume: Float = 0.5
    @Published var repeatMode: RepeatMode = .none
    @Published var playbackProgress: Double = 0.0

    private var audioPlayer: AVAudioPlayer?
    private var playlist: [Song] = []
    private var currentSongIndex = 0
    
    private var foregroundPauseTimer: Timer?
    private var backgroundPauseTimer: Timer?
    private var progressUpdateTimer: Timer?

    override init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [unowned self] event in
            if !self.isPlaying { self.play(); return .success }; return .commandFailed
        }
        commandCenter.pauseCommand.addTarget { [unowned self] event in
            if self.isPlaying { self.pause(); return .success }; return .commandFailed
        }
        commandCenter.nextTrackCommand.addTarget { [unowned self] event in
            self.nextTrack(); return .success
        }
        commandCenter.previousTrackCommand.addTarget { [unowned self] event in
            self.previousTrack(); return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let song = currentSong, let player = audioPlayer else { return }

        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = song.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = song.artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = song.album
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = player.duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate

        Task {
            var info = nowPlayingInfo
            if let artworkImage = await self.getArtwork(for: song) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
    
    private func getArtwork(for song: Song) async -> UIImage? {
        let filePath = song.path
        guard FileManager.default.isReadableFile(atPath: filePath.path) else {
            print("Artwork Error [NowPlaying]: File is not readable at path \(filePath.path)")
            return nil
        }
        
        let asset = AVURLAsset(url: song.path)
        do {
            let metadata = try await asset.load(.metadata)
            let artworkItems = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
            
            if let artworkItem = artworkItems.first, let imageData = try? await artworkItem.load(.dataValue) {
                return UIImage(data: imageData)
            }
        } catch {
            print("Failed to load artwork for Now Playing info: \(error)")
        }
        return nil
    }
    
    func setVolume(_ newVolume: Float) {
        let clampedVolume = max(0.0, min(1.0, newVolume))
        self.volume = clampedVolume
        audioPlayer?.volume = clampedVolume
    }

    func setPlaylist(songs: [Song], startAt index: Int, andPlay: Bool = true) {
        guard !songs.isEmpty, index < songs.count else { return }
        self.playlist = songs
        self.currentSongIndex = index
        self.currentSong = playlist[currentSongIndex]
        loadAudio()
        if andPlay {
            play()
        }
    }

    private func loadAudio() {
        guard let song = currentSong else { return }
        let filePath = song.path
        
        stopProgressTimer()
        playbackProgress = 0.0
        
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            print("Audio Error: File does not exist at path \(filePath.path)")
            return
        }
        
        guard FileManager.default.isReadableFile(atPath: filePath.path) else {
            print("Audio Error: File is not readable at path \(filePath.path)")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: filePath)
            
            audioPlayer?.delegate = self
            audioPlayer?.volume = self.volume
            audioPlayer?.prepareToPlay()
            updateNowPlayingInfo()
        } catch {
            print("Failed to load audio player for path \(filePath.path): \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("Error details: Domain: \(nsError.domain), Code: \(nsError.code), UserInfo: \(nsError.userInfo)")
            }
        }
    }

    func playPause() {
        if isPlaying { pause() } else { play() }
    }
    
    private func play() {
        audioPlayer?.play()
        isPlaying = true
        invalidateTimers()
        startProgressTimer()
        updateNowPlayingInfo()
    }
    
    private func pause() {
        audioPlayer?.pause()
        isPlaying = false
        startForegroundPauseTimer()
        stopProgressTimer()
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = self.isPlaying
        currentSongIndex = (currentSongIndex + 1) % playlist.count
        currentSong = playlist[currentSongIndex]
        loadAudio()
        if wasPlaying { play() }
    }

    func previousTrack() {
        guard !playlist.isEmpty else { return }
        let wasPlaying = self.isPlaying
        if let player = audioPlayer, player.currentTime > 3 {
            player.currentTime = 0
            if wasPlaying { play() }
            return
        }
        currentSongIndex = (currentSongIndex - 1 + playlist.count) % playlist.count
        currentSong = playlist[currentSongIndex]
        loadAudio()
        if wasPlaying { play() }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !flag { return }
        if repeatMode == .one {
            player.currentTime = 0; player.play()
        } else if currentSongIndex == playlist.count - 1 && repeatMode == .none {
            playbackProgress = 0; player.currentTime = 0; pause()
        } else {
            nextTrack()
        }
    }
    
    func setRepeatMode(to newMode: RepeatMode) {
        repeatMode = (repeatMode == newMode) ? .none : newMode
    }
    
    private func startProgressTimer() {
        stopProgressTimer()
        progressUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer, player.duration > 0 else { return }
            self.playbackProgress = player.currentTime / player.duration
        }
    }

    private func stopProgressTimer() {
        progressUpdateTimer?.invalidate()
        progressUpdateTimer = nil
    }
    
    func handleScenePhaseChange(newPhase: ScenePhase) {
        guard !isPlaying, currentSong != nil else { return }
        switch newPhase {
        case .background: invalidateTimers(); startBackgroundPauseTimer()
        case .active: invalidateTimers(); startForegroundPauseTimer()
        default: break
        }
    }

    private func invalidateTimers() {
        foregroundPauseTimer?.invalidate(); foregroundPauseTimer = nil
        backgroundPauseTimer?.invalidate(); backgroundPauseTimer = nil
    }

    private func startForegroundPauseTimer() {
        invalidateTimers()
        guard currentSong != nil else { return }
        foregroundPauseTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            self?.stopAndExit()
        }
    }

    private func startBackgroundPauseTimer() {
        invalidateTimers()
        guard currentSong != nil else { return }
        backgroundPauseTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
            self?.stopAndExit()
        }
    }
    
    private func stopAndExit() {
        stopProgressTimer()
        audioPlayer?.stop()
        isPlaying = false
        exit(0)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var musicPlayer = MusicPlayerManager()
    @StateObject private var libraryManager = MusicLibraryManager()
    @StateObject private var playlistManager = PlaylistManager()
    @StateObject private var viewRouter = ViewRouter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $viewRouter.currentTab) {
            PlayerView().tabItem {
                Image(systemName: "circle")
                Text(musicPlayer.currentSong?.title ?? "Player").lineLimit(1)
            }.tag(Tab.player)
            
            LibraryView().tabItem {
                Image(systemName: "circle")
                Text("Library")
            }.tag(Tab.library)

            PlaylistsView().tabItem {
                Image(systemName: "circle")
                Text("Playlists")
            }.tag(Tab.playlists)
        }
        .environmentObject(musicPlayer)
        .environmentObject(libraryManager)
        .environmentObject(playlistManager)
        .environmentObject(viewRouter)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            musicPlayer.handleScenePhaseChange(newPhase: newPhase)
        }
    }
}

// MARK: - Add Music View
struct AddMusicView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var libraryManager: MusicLibraryManager
    @EnvironmentObject var delegate: ExtensionDelegate // Get the delegate from the environment
    
    @State private var ipAddress = "192.168.86.250:8000" // Hardcoded for debugging

    var body: some View {
        VStack(spacing: 16) {
            if libraryManager.isLoading {
                ProgressView()
                Text(libraryManager.loadingMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            } else {
                Text("Enter IP Address")
                    .font(.headline)
                
                TextField("ex.192.168.1.10:8000", text: $ipAddress)
                    .textContentType(.URL)
                    .multilineTextAlignment(.center)
                
                if let errorMessage = libraryManager.downloadError {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                
                Button("Fetch Music") {
                    libraryManager.downloadError = nil
                    // Use the delegate that was passed into the environment directly.
                    // This is much safer and avoids the race condition.
                    libraryManager.startBackgroundDownload(from: ipAddress, delegate: delegate)
                }
                .disabled(ipAddress.isEmpty)
            }
        }
        .padding()
        .navigationTitle("Add Music")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    presentationMode.wrappedValue.dismiss()
                }
            }
        }
    }
}

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var libraryManager: MusicLibraryManager
    @EnvironmentObject var viewRouter: ViewRouter
    @State private var isShowingAddMusicSheet = false
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationStack(path: $viewRouter.libraryPath) {
            Group {
                if libraryManager.artists.isEmpty {
                    VStack(spacing: 12) {
                        Text("Library is Empty")
                            .font(.headline)
                        Button("Add Music") {
                            isShowingAddMusicSheet = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .navigationTitle("Library")
                } else {
                    List {
                        ForEach(libraryManager.artists) { artist in
                            NavigationLink(value: NavigationDestination.artist(artist)) {
                                Text(artist.name)
                            }
                        }
                    }
                    .navigationTitle("Library")
                    .toolbar {
                        // For watchOS, it's often better to have distinct placements.
                        // .cancellationAction places the button at the top-left.
                        ToolbarItem(placement: .cancellationAction) {
                             Button(role: .destructive) {
                                isShowingDeleteConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .tint(.red)
                            .disabled(libraryManager.artists.isEmpty)
                        }

                        // .primaryAction is usually at the bottom-right on watchOS.
                        ToolbarItem(placement: .primaryAction) {
                            Button(action: { isShowingAddMusicSheet = true }) {
                                Image(systemName: "plus")
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .artist(let artist): ArtistDetailView(artist: artist)
                case .album(let album): AlbumDetailView(album: album)
                }
            }
        }
        .sheet(isPresented: $isShowingAddMusicSheet) {
            NavigationView {
                AddMusicView()
            }
        }
        .confirmationDialog("Delete Library?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete All Music", role: .destructive) {
                libraryManager.deleteLibrary()
            }
        } message: {
            Text("This will permanently remove all downloaded music and library data.")
        }
    }
}


// MARK: - Artist and Album Detail Views
struct ArtistDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @EnvironmentObject var viewRouter: ViewRouter
    let artist: Artist
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle())
                Spacer()
                Button(action: {
                    let allSongs = artist.albums.flatMap { $0.songs }
                    if !allSongs.isEmpty {
                        musicPlayer.setPlaylist(songs: allSongs, startAt: 0)
                        viewRouter.currentTab = .player
                    }
                }) {
                    Image(systemName: "play.fill").font(.body.weight(.semibold))
                }
                .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle())
            }
            .padding(.horizontal).padding(.bottom, 4)

            Text(artist.name).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)

            List {
                ForEach(artist.albums) { album in
                    NavigationLink(value: NavigationDestination.album(album)) { Text(album.name) }
                }
            }
            .listStyle(.plain)
        }
        .padding(.top, 6).ignoresSafeArea(edges: .top).navigationBarHidden(true).navigationBarBackButtonHidden(true)
    }
}

struct AlbumDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @EnvironmentObject var viewRouter: ViewRouter
    @State private var songToAddToPlaylist: Song?
    let album: Album

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "chevron.left").font(.body.weight(.semibold))
                }
                .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle())
                Spacer()
                Button(action: {
                    if !album.songs.isEmpty {
                        musicPlayer.setPlaylist(songs: album.songs, startAt: 0)
                        viewRouter.currentTab = .player
                    }
                }) {
                    Image(systemName: "play.fill").font(.body.weight(.semibold))
                }
                .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle())
            }
            .padding(.horizontal).padding(.bottom, 4)
            
            List {
                VStack {
                    ArtworkView(song: album.songs.first, size: 70).padding(.bottom, 4)
                    Text(album.name).font(.headline).fontWeight(.bold).multilineTextAlignment(.center)
                    Text(album.songs.first?.artist ?? "").font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center).listRowBackground(Color.clear)
                
                ForEach(album.songs) { song in
                    Text(song.title)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if let index = album.songs.firstIndex(of: song) {
                                musicPlayer.setPlaylist(songs: album.songs, startAt: index)
                                viewRouter.currentTab = .player
                            }
                        }
                        .onLongPressGesture { self.songToAddToPlaylist = song }
                }
            }
            .listStyle(.plain)
        }
        .padding(.top, 6).ignoresSafeArea(edges: .top).navigationBarHidden(true).navigationBarBackButtonHidden(true)
        .sheet(item: $songToAddToPlaylist) { song in
            PlayerAddToPlaylistView(song: song) { _ in }
        }
    }
}

// MARK: - Playlist Views
struct PlaylistsView: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @State private var isShowingCreateSheet = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlistManager.playlists) { playlist in
                    NavigationLink(destination: PlaylistDetailView(playlistID: playlist.id)) { Text(playlist.name) }
                }
                .onDelete { indexSet in
                    playlistManager.playlists.remove(atOffsets: indexSet)
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isShowingCreateSheet = true }) { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isShowingCreateSheet) {
                NavigationView {
                    VStack {
                        TextField("Playlist Name", text: $newPlaylistName).padding()
                        Spacer()
                        Button("Create") {
                            if !newPlaylistName.isEmpty {
                                playlistManager.createPlaylist(name: newPlaylistName)
                                newPlaylistName = ""; isShowingCreateSheet = false
                            }
                        }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(newPlaylistName.isEmpty).padding()
                    }
                    .navigationTitle("New Playlist")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: { isShowingCreateSheet = false; newPlaylistName = "" }) { Image(systemName: "xmark") }
                        }
                    }
                }
            }
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @EnvironmentObject var viewRouter: ViewRouter
    @EnvironmentObject var playlistManager: PlaylistManager
    let playlistID: UUID
    @State private var isAddingSongs = false

    private var playlist: Playlist? { playlistManager.playlists.first { $0.id == playlistID } }
    
    var body: some View {
        if let playlist = playlist {
            VStack(spacing: 0) {
                HStack {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold))
                    }
                    .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle())
                    Spacer()
                    Button(action: { isAddingSongs = true }) {
                        Image(systemName: "plus").font(.body.weight(.semibold))
                    }
                    .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle())
                }
                .padding(.horizontal).padding(.bottom, 4)
                
                Text(playlist.name).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 8)
                
                ZStack {
                    List {
                        ForEach(playlist.songs) { song in
                             VStack(alignment: .leading) {
                                 Text(song.title).font(.subheadline)
                                 Text(song.artist).font(.footnote).foregroundColor(.secondary)
                             }
                             .contentShape(Rectangle())
                             .onTapGesture {
                                 if let index = playlist.songs.firstIndex(of: song) {
                                     musicPlayer.setPlaylist(songs: playlist.songs, startAt: index)
                                     viewRouter.currentTab = .player
                                 }
                             }
                        }
                        .onDelete { indexSet in
                            playlistManager.removeSongs(at: indexSet, from: playlist.id)
                        }
                    }
                    .listStyle(.plain)

                    if playlist.songs.isEmpty {
                        VStack {
                            Text("This Playlist is Empty").font(.headline)
                            Text("Tap the '+' button to add songs.").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                        }
                    }
                }
            }
            .padding(.top, 6).ignoresSafeArea(edges: .top).navigationBarHidden(true).navigationBarBackButtonHidden(true)
            .sheet(isPresented: $isAddingSongs) {
                PlaylistAddSongView(playlist: playlist)
            }
        } else {
            Text("Playlist not found").foregroundColor(.secondary)
        }
    }
}

struct PlaylistAddSongView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var libraryManager: MusicLibraryManager
    @EnvironmentObject var playlistManager: PlaylistManager
    let playlist: Playlist

    var body: some View {
        NavigationView {
            List {
                ForEach(libraryManager.artists) { artist in
                    Section(header: Text(artist.name)) {
                        ForEach(artist.albums) { album in
                            ForEach(album.songs) { song in
                                Button(action: {
                                    let isSongInPlaylist = playlistManager.playlists.first { $0.id == playlist.id }?.songs.contains { $0.id == song.id } == true
                                    if isSongInPlaylist {
                                        playlistManager.removeSong(song, from: playlist.id)
                                    } else {
                                        playlistManager.addSong(song, to: playlist.id)
                                    }
                                }) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(song.title)
                                            Text(album.name).font(.caption).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        if playlistManager.playlists.first(where: { $0.id == playlist.id })?.songs.contains(where: { $0.id == song.id }) == true {
                                            Image(systemName: "checkmark").foregroundColor(.accentColor)
                                        }
                                    }
                                }
                                .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to \(playlist.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
        }
    }
}

// MARK: - Artwork View
struct ArtworkView: View {
    let song: Song?
    let size: CGFloat
    @State private var artworkData: Data?
    
    var body: some View {
        Group {
            if let data = artworkData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note").font(.system(size: size / 1.6)).foregroundColor(.gray.opacity(0.5))
            }
        }
        .frame(width: size, height: size).background(Color.white.opacity(0.1)).cornerRadius(8).shadow(radius: 5)
        .task(id: song?.id) { await loadArtwork() }
    }
    
    private func loadArtwork() async {
        artworkData = nil
        guard let currentSong = song else { return }
        let filePath = currentSong.path

        guard FileManager.default.isReadableFile(atPath: filePath.path) else {
            print("Artwork Error: File is not readable at path \(filePath.path)")
            return
        }

        do {
            let asset = AVURLAsset(url: filePath)
            let allMetadata = try await asset.load(.metadata)
            let artworkItems = allMetadata.filter { $0.commonKey == .commonKeyArtwork }
            
            if let artworkItem = artworkItems.first, let artworkDataValue = try? await artworkItem.load(.dataValue) {
                self.artworkData = artworkDataValue
            }
        } catch {
            print("Failed to load artwork: \(error)")
            self.artworkData = nil
        }
    }
}

// MARK: - UIImage Color Extension
extension UIImage {
    private func averageColor(from cgImage: CGImage) -> Color? {
        guard let dataProvider = cgImage.dataProvider, let data = dataProvider.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }
        let totalPixels = cgImage.width * cgImage.height
        guard totalPixels > 0 else { return nil }

        var totalR: CGFloat = 0, totalG: CGFloat = 0, totalB: CGFloat = 0
        
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                if offset + 2 < CFDataGetLength(data) {
                    totalR += CGFloat(ptr[offset])
                    totalG += CGFloat(ptr[offset + 1])
                    totalB += CGFloat(ptr[offset + 2])
                }
            }
        }
        
        let avgR = (totalR / CGFloat(totalPixels)) / 255.0
        let avgG = (totalG / CGFloat(totalPixels)) / 255.0
        let avgB = (totalB / CGFloat(totalPixels)) / 255.0
        
        return Color(red: avgR, green: avgG, blue: avgB)
    }

    var gradientColors: [Color] {
        let thumbnailSize = CGSize(width: 40, height: 40)
        guard let cgImage = self.cgImage, let colorSpace = cgImage.colorSpace,
              let context = CGContext(data: nil, width: Int(thumbnailSize.width), height: Int(thumbnailSize.height), bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [.black, .gray.opacity(0.5)] }
        
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: thumbnailSize))

        guard let thumbnailCgImage = context.makeImage() else { return [.black, .gray.opacity(0.5)] }

        let topRect = CGRect(x: 0, y: 0, width: thumbnailCgImage.width, height: thumbnailCgImage.height / 2)
        let bottomRect = CGRect(x: 0, y: thumbnailCgImage.height / 2, width: thumbnailCgImage.width, height: thumbnailCgImage.height / 2)
        
        var topColor: Color = .black
        var bottomColor: Color = .gray
        
        if let topCgImage = thumbnailCgImage.cropping(to: topRect) { topColor = averageColor(from: topCgImage) ?? .black }
        if let bottomCgImage = thumbnailCgImage.cropping(to: bottomRect) { bottomColor = averageColor(from: bottomCgImage) ?? .gray }
        
        return [topColor, bottomColor]
    }
}

// MARK: - Add/Create Playlist Views
struct PlayerCreateAndAddView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var playlistManager: PlaylistManager
    let song: Song
    let onCreated: (String) -> Void
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationView {
            VStack {
                Text("Create a new playlist for '\(song.title)'.")
                    .multilineTextAlignment(.center).padding()
                TextField("Playlist Name", text: $newPlaylistName).padding()
                Spacer()
                Button("Create & Add") {
                    if !newPlaylistName.isEmpty {
                        playlistManager.createPlaylist(name: newPlaylistName)
                        if let newPlaylist = playlistManager.playlists.last {
                            playlistManager.addSong(song, to: newPlaylist.id)
                            presentationMode.wrappedValue.dismiss()
                            onCreated(newPlaylist.name)
                        }
                    }
                }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity).disabled(newPlaylistName.isEmpty).padding()
            }
            .navigationTitle("New Playlist")
        }
    }
}

struct PlayerAddToPlaylistView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var playlistManager: PlaylistManager
    let song: Song
    let onAdded: (String) -> Void
    @State private var isCreatingNewPlaylist = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Existing Playlists")) {
                    if playlistManager.playlists.isEmpty {
                        Text("No playlists found.").foregroundColor(.secondary)
                    } else {
                        ForEach(playlistManager.playlists) { playlist in
                            Button(action: {
                                playlistManager.addSong(song, to: playlist.id)
                                presentationMode.wrappedValue.dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onAdded(playlist.name) }
                            }) { Text(playlist.name) }
                        }
                    }
                }
                Section {
                    Button("Create New Playlist") { isCreatingNewPlaylist = true }
                }
            }
            .navigationTitle("Add to Playlist")
            .sheet(isPresented: $isCreatingNewPlaylist) {
                PlayerCreateAndAddView(song: song) { newPlaylistName in
                    presentationMode.wrappedValue.dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { onAdded(newPlaylistName) }
                }
            }
        }
    }
}

// MARK: - Player View
struct PlayerView: View {
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @EnvironmentObject var libraryManager: MusicLibraryManager
    @EnvironmentObject var viewRouter: ViewRouter
    
    @State private var crownRotation: Double = 0.5
    @State private var backgroundColors: [Color] = [.black, .gray.opacity(0.5)]
    
    @State private var songForPlaylistAction: Song?
    @State private var showOptionsMenu = false
    @State private var toastMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .top, endPoint: .bottom)
                .animation(.spring(), value: backgroundColors)
                .ignoresSafeArea()

            VStack {
                SongInfoView(song: musicPlayer.currentSong)
                Spacer()
                PlayerControlsView(musicPlayer: musicPlayer)
            }
            .padding(.vertical)
            
            ToastView(message: $toastMessage)
        }
        .focusable()
        .digitalCrownRotation($crownRotation, from: 0.0, through: 1.0, by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { crownRotation = 1.0 - Double(musicPlayer.volume) }
        .onChange(of: crownRotation) { _, newValue in musicPlayer.setVolume(Float(1.0 - newValue)) }
        .onChange(of: musicPlayer.volume) { _, newVolume in crownRotation = 1.0 - Double(newVolume) }
        .task(id: musicPlayer.currentSong?.id) { await updateBackgroundColor() }
        .navigationTitle("Now Playing")
        .overlay(alignment: .topTrailing) {
            if musicPlayer.currentSong != nil {
                Button(action: { showOptionsMenu = true }) { Image(systemName: "ellipsis").font(.body) }
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
                    .padding(.trailing)
            }
        }
        .confirmationDialog("Actions", isPresented: $showOptionsMenu, titleVisibility: .hidden) {
            Button("Add to Playlist") { songForPlaylistAction = musicPlayer.currentSong }
            
            if let song = musicPlayer.currentSong, let artist = libraryManager.artists.first(where: { $0.name == song.artist }) {
                if let album = artist.albums.first(where: { $0.name == song.album }) {
                    Button("Go to Album") { viewRouter.navigateTo(artist: artist, album: album) }
                }
                Button("Go to Artist") { viewRouter.navigateTo(artist: artist, album: nil) }
            }
            
            Button(musicPlayer.repeatMode == .all ? "Repeat All ✓" : "Repeat All") { musicPlayer.setRepeatMode(to: .all) }
            Button(musicPlayer.repeatMode == .one ? "Repeat Song ✓" : "Repeat Song") { musicPlayer.setRepeatMode(to: .one) }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(item: $songForPlaylistAction) { song in
            PlayerAddToPlaylistView(song: song) { playlistName in
                withAnimation { toastMessage = "Added to \"\(playlistName)\"" }
            }
        }
    }

    private func updateBackgroundColor() async {
        guard let currentSong = musicPlayer.currentSong else {
            backgroundColors = [.black, .gray.opacity(0.5)]; return
        }

        let colors = await Task.detached(priority: .background) { () -> [Color] in
            guard let artworkData = try? await getArtworkData(for: currentSong), let uiImage = UIImage(data: artworkData) else {
                return [.black, .gray.opacity(0.5)]
            }
            return uiImage.gradientColors
        }.value
        
        self.backgroundColors = colors
    }
    
    private func getArtworkData(for song: Song) async throws -> Data? {
        let filePath = song.path
        guard FileManager.default.isReadableFile(atPath: filePath.path) else {
            print("Artwork Error [PlayerView]: File is not readable at path \(filePath.path)")
            return nil
        }

        let asset = AVURLAsset(url: song.path)
        let metadata = try await asset.load(.metadata)
        let artworkItems = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
        
        if let artworkItem = artworkItems.first {
            return try await artworkItem.load(.dataValue)
        }
        return nil
    }
}

// MARK: - PlayerView Subviews
private struct SongInfoView: View {
    let song: Song?
    
    var body: some View {
        VStack {
            ArtworkView(song: song, size: 70)
            
            if let song = song {
                Text(song.title).font(.headline).bold().multilineTextAlignment(.center).padding(.top, 5).padding(.horizontal)
                Text("\(song.artist) - \(song.album)").font(.caption).bold().foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center).padding(.horizontal)
            } else {
                Text("No Song Selected").font(.subheadline).padding(.top, 10)
                Text("Start in your library").font(.footnote).foregroundColor(.gray)
            }
        }
    }
}

private struct PlayerControlsView: View {
    @ObservedObject var musicPlayer: MusicPlayerManager
    
    var body: some View {
        HStack(spacing: 15) {
            Button(action: { musicPlayer.previousTrack() }) { Image(systemName: "backward.fill").font(.title3) }
                .frame(width: 35, height: 35).background(Color.white.opacity(0.15)).clipShape(Circle()).disabled(musicPlayer.currentSong == nil)

            ZStack {
                Circle().stroke(Color.white.opacity(0.3), lineWidth: 4)
                Circle().trim(from: 0.0, to: musicPlayer.playbackProgress).stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                Button(action: { musicPlayer.playPause() }) {
                    Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 26)).padding(.leading, musicPlayer.isPlaying ? 0 : 2)
                }
                .frame(width: 30, height: 30).background(Color.white.opacity(0.15)).clipShape(Circle()).disabled(musicPlayer.currentSong == nil)
            }
            .frame(width: 40, height: 40)

            Button(action: { musicPlayer.nextTrack() }) { Image(systemName: "forward.fill").font(.title3) }
                .frame(width: 35, height: 35).background(Color.white.opacity(0.15)).clipShape(Circle()).disabled(musicPlayer.currentSong == nil)
        }
        .padding(.bottom)
    }
}

private struct ToastView: View {
    @Binding var message: String?
    
    var body: some View {
        VStack {
            if let msg = message {
                Spacer()
                Text(msg)
                    .padding()
                    .background(.thinMaterial)
                    .foregroundColor(.primary)
                    .cornerRadius(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            withAnimation {
                                message = nil
                            }
                        }
                    }
            }
        }
        .zIndex(1)
    }
}


// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
