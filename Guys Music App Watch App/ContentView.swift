import SwiftUI
import AVFoundation
import MediaPlayer
import CoreGraphics

// MARK: - Navigation
// ADDED: Enum to define the types of views we can navigate to.
enum NavigationDestination: Hashable {
    case artist(Artist)
    case album(Album)
}

enum Tab {
    case player, library, playlists
}

class ViewRouter: ObservableObject {
    @Published var currentTab: Tab = .library
    
    // UPDATED: Use a navigation path for modern navigation
    @Published var libraryPath = [NavigationDestination]()

    // UPDATED: Helper to trigger the navigation flow
    func navigateTo(artist: Artist, album: Album?) {
        // Switch to the library tab first
        self.currentTab = .library

        // Then, on the next run loop, set the path. This ensures the
        // view has time to switch tabs before the navigation is triggered.
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
    // Storing the path as a relative string for Codable conformance
    let relativePath: String

    var path: URL {
        // Reconstruct the full URL when needed
        return Bundle.main.resourceURL!.appendingPathComponent(relativePath)
    }

    // Custom coding keys to handle the non-codable URL
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, relativePath
    }
}

struct Album: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var songs: [Song]
}

struct Artist: Identifiable, Hashable {
    let id = UUID()
    let name: String
    var albums: [Album]
}

struct Playlist: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var songs: [Song]
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
    /// Removes leading track numbers (e.g., "01. ", "02 - ") from a string using regular expressions.
    func removingTrackNumber() -> String {
        let pattern = "^\\d+\\s*([.-]|\\s-)?\\s*"
        return self.replacingOccurrences(of: pattern, with: "", options: .regularExpression, range: nil)
    }
}

// MARK: - Music Library Manager
class MusicLibraryManager: ObservableObject {
    @Published var artists = [Artist]()

    init() {
        loadLibrary()
    }

    func loadLibrary() {
        let fileManager = FileManager.default
        guard let bundleRootURL = Bundle.main.resourceURL,
              let musicRootURL = Bundle.main.url(forResource: "Music", withExtension: nil) else {
            print("Music directory not found in the app bundle.")
            return
        }

        var loadedArtists = [String: [String: [Song]]]() // Artist -> Album -> Songs

        let enumerator = fileManager.enumerator(at: musicRootURL,
                                                includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
                                                options: [.skipsHiddenFiles],
                                                errorHandler: nil)

        guard let filePaths = enumerator?.allObjects as? [URL] else {
            print("Could not enumerate files.")
            return
        }

        for url in filePaths {
            if url.pathExtension.lowercased() == "mp3" {
                let pathComponents = url.pathComponents
                
                // Expecting structure: .../Music/Artist/Album/Song.mp3
                if pathComponents.count >= 4 {
                    let songTitle = url.deletingPathExtension().lastPathComponent.removingTrackNumber()
                    let albumName = url.deletingLastPathComponent().lastPathComponent
                    let artistName = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                    
                    let relativePath = url.path.replacingOccurrences(of: bundleRootURL.path, with: "")
                    let song = Song(title: songTitle, artist: artistName, album: albumName, relativePath: relativePath)
                    
                    // Group songs by artist and album
                    if loadedArtists[artistName] == nil {
                        loadedArtists[artistName] = [:]
                    }
                    if loadedArtists[artistName]![albumName] == nil {
                        loadedArtists[artistName]![albumName] = []
                    }
                    loadedArtists[artistName]![albumName]?.append(song)
                }
            }
        }

        // Convert the dictionary structure to the Artist/Album model arrays
        var finalArtists = [Artist]()
        for (artistName, albumsDict) in loadedArtists {
            var artistAlbums = [Album]()
            for (albumName, songs) in albumsDict {
                artistAlbums.append(Album(name: albumName, songs: songs.sorted { $0.title < $1.title }))
            }
            finalArtists.append(Artist(name: artistName, albums: artistAlbums.sorted { $0.name < $1.name }))
        }

        self.artists = finalArtists.sorted { $0.name < $1.name }
        
        if self.artists.isEmpty {
            print("Finished loading library, but no artists were found. Please check your folder structure and that the 'Music' folder is added correctly as a blue folder reference.")
        } else {
            print("Successfully loaded \(self.artists.count) artists.")
        }
    }
}


// MARK: - Music Player Manager
class MusicPlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentSong: Song?
    @Published var volume: Float = 0.5

    private var audioPlayer: AVAudioPlayer?
    private var playlist: [Song] = []
    private var currentSongIndex = 0
    
    // ADDED: Timers to manage inactivity and app termination.
    private var foregroundPauseTimer: Timer?
    private var backgroundPauseTimer: Timer?

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
    
    // MARK: - Remote Command Center Setup
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [unowned self] event in
            if !self.isPlaying {
                self.play()
                return .success
            }
            return .commandFailed
        }

        commandCenter.pauseCommand.addTarget { [unowned self] event in
            if self.isPlaying {
                self.pause()
                return .success
            }
            return .commandFailed
        }

        commandCenter.nextTrackCommand.addTarget { [unowned self] event in
            self.nextTrack()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [unowned self] event in
            self.previousTrack()
            return .success
        }
    }

    // MARK: - Now Playing Info
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
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: song.path)
            audioPlayer?.delegate = self
            audioPlayer?.volume = self.volume
            audioPlayer?.prepareToPlay()
            updateNowPlayingInfo()
        } catch {
            print("Failed to load audio player for path \(song.path): \(error.localizedDescription)")
        }
    }

    func playPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    // UPDATED: Starts playback and invalidates any inactivity timers.
    private func play() {
        audioPlayer?.play()
        isPlaying = true
        invalidateTimers() // When music is playing, we don't need to quit.
        updateNowPlayingInfo()
    }
    
    // UPDATED: Pauses playback and starts the foreground inactivity timer.
    private func pause() {
        audioPlayer?.pause()
        isPlaying = false
        startForegroundPauseTimer() // Start timer when paused.
        updateNowPlayingInfo()
    }

    func nextTrack() {
        guard !playlist.isEmpty else { return }
        currentSongIndex = (currentSongIndex + 1) % playlist.count
        currentSong = playlist[currentSongIndex]
        loadAudio()
        if isPlaying { play() }
    }

    func previousTrack() {
        guard !playlist.isEmpty else { return }
        currentSongIndex = (currentSongIndex - 1 + playlist.count) % playlist.count
        currentSong = playlist[currentSongIndex]
        loadAudio()
        if isPlaying { play() }
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            nextTrack()
        }
    }
    
    // MARK: - ADDED: Inactivity and App Lifecycle Management
    
    /// Handles changes in the app's scene phase (e.g., moving to background).
    /// - Parameter newPhase: The new `ScenePhase` provided by SwiftUI.
    func handleScenePhaseChange(newPhase: ScenePhase) {
        // This logic should only run if music is paused and a song is loaded.
        guard !isPlaying, currentSong != nil else { return }

        switch newPhase {
        case .background:
            // App has been backgrounded while paused. Invalidate the foreground
            // timer and start the shorter (1 minute) background timer.
            invalidateTimers()
            startBackgroundPauseTimer()
        case .active:
            // App has returned to the foreground while paused. Invalidate the
            // background timer and restart the standard (2 minute) foreground timer.
            invalidateTimers()
            startForegroundPauseTimer()
        default:
            // We don't need to handle .inactive for this feature.
            break
        }
    }

    /// Stops any running inactivity timers.
    private func invalidateTimers() {
        foregroundPauseTimer?.invalidate()
        foregroundPauseTimer = nil
        backgroundPauseTimer?.invalidate()
        backgroundPauseTimer = nil
    }

    /// Starts a 2-minute timer. If it fires, the app will close.
    /// This is used when the app is paused in the foreground.
    private func startForegroundPauseTimer() {
        invalidateTimers()
        guard currentSong != nil else { return }
        foregroundPauseTimer = Timer.scheduledTimer(withTimeInterval: 120.0, repeats: false) { [weak self] _ in
            print("Foreground pause limit (2 minutes) reached. Exiting.")
            self?.stopAndExit()
        }
    }

    /// Starts a 1-minute timer. If it fires, the app will close.
    /// This is used when the app is paused in the background.
    private func startBackgroundPauseTimer() {
        invalidateTimers()
        guard currentSong != nil else { return }
        backgroundPauseTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: false) { [weak self] _ in
            print("Background pause limit (1 minute) reached. Exiting.")
            self?.stopAndExit()
        }
    }
    
    /// A helper function to safely stop the audio player and exit the application.
    private func stopAndExit() {
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
    
    // ADDED: Environment property to detect scene phase changes (e.g., backgrounding).
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $viewRouter.currentTab) {
            PlayerView()
                .tabItem {
                    VStack {
                        // UPDATED: Icon changed to a circle.
                        Image(systemName: "circle.fill")
                            .font(.subheadline)
                        Text("Player")
                            .font(.caption2)
                    }
                }
                .tag(Tab.player)
            
            LibraryView()
                 .tabItem {
                    VStack {
                        // UPDATED: Icon changed to a circle.
                        Image(systemName: "circle.fill")
                            .font(.subheadline)
                        Text("Library")
                            .font(.caption2)
                    }
                 }
                 .tag(Tab.library)

            PlaylistsView()
                .tabItem {
                    VStack {
                        // UPDATED: Icon changed to a circle.
                        Image(systemName: "circle.fill")
                            .font(.subheadline)
                        Text("Playlists")
                            .font(.caption2)
                    }
                }
                .tag(Tab.playlists)
        }
        .environmentObject(musicPlayer)
        .environmentObject(libraryManager)
        .environmentObject(playlistManager)
        .environmentObject(viewRouter)
        // ADDED: A modifier to watch for scene phase changes and notify the music player.
        .onChange(of: scenePhase) { oldValue, newPhase in
            musicPlayer.handleScenePhaseChange(newPhase: newPhase)
        }
    }
}

// MARK: - Library View
// UPDATED: Replaced NavigationView and deprecated NavigationLinks with NavigationStack.
struct LibraryView: View {
    @EnvironmentObject var libraryManager: MusicLibraryManager
    @EnvironmentObject var viewRouter: ViewRouter

    var body: some View {
        NavigationStack(path: $viewRouter.libraryPath) {
            List {
                ForEach(libraryManager.artists) { artist in
                    NavigationLink(value: NavigationDestination.artist(artist)) {
                        Text(artist.name)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: NavigationDestination.self) { destination in
                switch destination {
                case .artist(let artist):
                    ArtistDetailView(artist: artist)
                case .album(let album):
                    AlbumDetailView(album: album)
                }
            }
        }
    }
}

// MARK: - Artist and Album Detail Views
// UPDATED: Replaced deprecated NavigationLinks with value-based links.
struct ArtistDetailView: View {
    let artist: Artist
    
    var body: some View {
        List {
            ForEach(artist.albums) { album in
                NavigationLink(value: NavigationDestination.album(album)) {
                    Text(album.name)
                }
            }
        }
        .navigationTitle(artist.name)
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @EnvironmentObject var viewRouter: ViewRouter
    @State private var songToAddToPlaylist: Song?
    let album: Album

    var body: some View {
        List {
            VStack {
                ArtworkView(song: album.songs.first, size: 70)
                Text(album.name)
                    .font(.headline)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                Text(album.songs.first?.artist ?? "")
                     .font(.subheadline)
                     .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)

            ForEach(album.songs) { song in
                Text(song.title)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        print("Tapped on song: \(song.title)")
                        if let index = album.songs.firstIndex(of: song) {
                            musicPlayer.setPlaylist(songs: album.songs, startAt: index)
                            viewRouter.currentTab = .player
                        }
                    }
                    .onLongPressGesture {
                        self.songToAddToPlaylist = song
                    }
            }
        }
        .sheet(item: $songToAddToPlaylist) { song in
            PlayerAddToPlaylistView(song: song) { _ in }
        }
    }
}

// MARK: - Playlist Views
// UPDATED: Replaced NavigationView with NavigationStack.
struct PlaylistsView: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @State private var isShowingCreateSheet = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(playlistManager.playlists) { playlist in
                    NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                        Text(playlist.name)
                    }
                }
                .onDelete { indexSet in
                    playlistManager.playlists.remove(atOffsets: indexSet)
                }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isShowingCreateSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingCreateSheet) {
                NavigationView {
                    VStack {
                        TextField("Playlist Name", text: $newPlaylistName)
                            .padding()
                        
                        Spacer()
                        
                        Button("Create") {
                            if !newPlaylistName.isEmpty {
                                playlistManager.createPlaylist(name: newPlaylistName)
                                newPlaylistName = ""
                                isShowingCreateSheet = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(newPlaylistName.isEmpty)
                        .padding()
                    }
                    .navigationTitle("New Playlist")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(action: {
                                isShowingCreateSheet = false
                                newPlaylistName = ""
                            }) {
                                Image(systemName: "xmark")
                            }
                        }
                    }
                }
            }
        }
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @EnvironmentObject var viewRouter: ViewRouter
    let playlist: Playlist
    
    var body: some View {
        List {
            ForEach(playlist.songs) { song in
                 VStack(alignment: .leading) {
                    Text(song.title).font(.subheadline)
                    Text(song.artist).font(.footnote).foregroundColor(.secondary)
                 }
                 .contentShape(Rectangle())
                 .onTapGesture {
                    print("Tapped on song: \(song.title)")
                    if let index = playlist.songs.firstIndex(of: song) {
                        musicPlayer.setPlaylist(songs: playlist.songs, startAt: index)
                        viewRouter.currentTab = .player
                    }
                }
            }
        }
        .navigationTitle(playlist.name)
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
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size / 1.6))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.1))
        .cornerRadius(8)
        .shadow(radius: 5)
        .task(id: song?.id) {
            await loadArtwork()
        }
    }
    
    private func loadArtwork() async {
        guard let currentSong = song else {
            artworkData = nil
            return
        }
        
        do {
            let asset = AVURLAsset(url: currentSong.path)
            let allMetadata = try await asset.load(.metadata)
            let artworkItems = allMetadata.filter { $0.commonKey == .commonKeyArtwork }
            
            if let artworkItem = artworkItems.first,
               let artworkDataValue = try? await artworkItem.load(.dataValue) {
                self.artworkData = artworkDataValue
            } else {
                self.artworkData = nil
            }
        } catch {
            print("Failed to load artwork: \(error)")
            self.artworkData = nil
        }
    }
}

// MARK: - UIImage Color Extension
extension UIImage {

    /// Calculates the average color from a given Core Graphics image.
    private func averageColor(from cgImage: CGImage) -> Color? {
        // Ensure we have a data provider.
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else {
            return nil
        }
        
        // Ensure we can calculate bytes per pixel.
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil } // Need at least R, G, B.
        
        // Ensure the image has pixels.
        let totalPixels = cgImage.width * cgImage.height
        guard totalPixels > 0 else { return nil }

        // Loop through all pixels to calculate total color values.
        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        
        for y in 0..<cgImage.height {
            for x in 0..<cgImage.width {
                let offset = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                // Check buffer to avoid reading out of bounds
                if offset + 2 < CFDataGetLength(data) {
                    totalR += CGFloat(ptr[offset])
                    totalG += CGFloat(ptr[offset + 1])
                    totalB += CGFloat(ptr[offset + 2])
                }
            }
        }
        
        // Calculate the average R, G, B values.
        let avgR = (totalR / CGFloat(totalPixels)) / 255.0
        let avgG = (totalG / CGFloat(totalPixels)) / 255.0
        let avgB = (totalB / CGFloat(totalPixels)) / 255.0
        
        return Color(red: avgR, green: avgG, blue: avgB)
    }

    /// Generates two colors for a gradient by averaging the top and bottom halves of the image.
    var gradientColors: [Color] {
        // We will process a small thumbnail for performance.
        let thumbnailSize = CGSize(width: 40, height: 40)
        
        // Create a Core Graphics context to draw the thumbnail.
        guard let cgImage = self.cgImage,
              let colorSpace = cgImage.colorSpace,
              let context = CGContext(data: nil,
                                      width: Int(thumbnailSize.width),
                                      height: Int(thumbnailSize.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // Fallback if context creation fails.
            return [.black, .gray.opacity(0.5)]
        }
        
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: thumbnailSize))

        // Get the thumbnail image from the context.
        guard let thumbnailCgImage = context.makeImage() else {
            return [.black, .gray.opacity(0.5)]
        }

        // Define the top and bottom halves of the thumbnail.
        let topRect = CGRect(x: 0, y: 0, width: thumbnailCgImage.width, height: thumbnailCgImage.height / 2)
        let bottomRect = CGRect(x: 0, y: thumbnailCgImage.height / 2, width: thumbnailCgImage.width, height: thumbnailCgImage.height / 2)
        
        var topColor: Color = .black
        var bottomColor: Color = .gray
        
        // Crop the top half and calculate its average color.
        if let topCgImage = thumbnailCgImage.cropping(to: topRect) {
            topColor = averageColor(from: topCgImage) ?? .black
        }
        
        // Crop the bottom half and calculate its average color.
        if let bottomCgImage = thumbnailCgImage.cropping(to: bottomRect) {
            bottomColor = averageColor(from: bottomCgImage) ?? .gray
        }
        
        return [topColor, bottomColor]
    }
}

// ADDED: A view for creating a new playlist and adding the song in one flow.
struct PlayerCreateAndAddView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var playlistManager: PlaylistManager
    let song: Song
    let onCreated: (String) -> Void // Callback with the name of the new playlist
    
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationView {
            VStack {
                Text("Create a new playlist for '\(song.title)'.")
                    .multilineTextAlignment(.center)
                    .padding()
                
                TextField("Playlist Name", text: $newPlaylistName)
                    .padding()
                
                Spacer()
                
                // UPDATED: The explicit "Cancel" button is removed to rely on the system 'X' button.
                Button("Create & Add") {
                    if !newPlaylistName.isEmpty {
                        // 1. Create the empty playlist
                        playlistManager.createPlaylist(name: newPlaylistName)
                        
                        // 2. Find the new playlist's ID (the last one added)
                        if let newPlaylist = playlistManager.playlists.last {
                            // 3. Add the current song to it
                            playlistManager.addSong(song, to: newPlaylist.id)
                            
                            // 4. Dismiss this sheet and call the completion handler
                            presentationMode.wrappedValue.dismiss()
                            onCreated(newPlaylist.name)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(newPlaylistName.isEmpty)
                .padding()
            }
            .navigationTitle("New Playlist")
        }
    }
}


// UPDATED: This view now includes an option to create a new playlist.
struct PlayerAddToPlaylistView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var playlistManager: PlaylistManager
    let song: Song
    let onAdded: (String) -> Void // Callback with playlist name

    @State private var isCreatingNewPlaylist = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Existing Playlists")) {
                    // Show message if no playlists exist
                    if playlistManager.playlists.isEmpty {
                        Text("No playlists found.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(playlistManager.playlists) { playlist in
                            Button(action: {
                                playlistManager.addSong(song, to: playlist.id)
                                presentationMode.wrappedValue.dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                    onAdded(playlist.name)
                                }
                            }) {
                                Text(playlist.name)
                            }
                        }
                    }
                }
                
                Section {
                    Button("Create New Playlist") {
                        isCreatingNewPlaylist = true
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            // REMOVED: The explicit "Cancel" button in the toolbar is no longer needed.
            // The system provides a standard dismiss ('X') button for sheets.
            .sheet(isPresented: $isCreatingNewPlaylist) {
                PlayerCreateAndAddView(song: song) { newPlaylistName in
                    // This callback is triggered from the create view.
                    // Dismiss the current (add to playlist) view.
                    presentationMode.wrappedValue.dismiss()
                    
                    // And then call the original onAdded callback to show the toast.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                         onAdded(newPlaylistName)
                    }
                }
            }
        }
    }
}


// MARK: - Player View
struct PlayerView: View {
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    // ADDED: Environment objects for navigation.
    @EnvironmentObject var libraryManager: MusicLibraryManager
    @EnvironmentObject var viewRouter: ViewRouter
    
    // UPDATED: This state variable now tracks the raw crown input.
    @State private var crownRotation: Double = 0.5
    @State private var backgroundColors: [Color] = [.black, .gray.opacity(0.5)]
    
    // UPDATED: State for managing the sheet presentation and success message
    @State private var songForPlaylistAction: Song?
    @State private var showOptionsMenu = false
    @State private var toastMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .top, endPoint: .bottom)
                .animation(.spring(), value: backgroundColors)
                .ignoresSafeArea()

            VStack {
                // UPDATED: The 'size' parameter is now passed to the ArtworkView.
                ArtworkView(song: musicPlayer.currentSong, size: 80)
                
                if let song = musicPlayer.currentSong {
                    Text(song.title)
                        .font(.headline).bold()
                        .multilineTextAlignment(.center)
                        .padding(.top, 5)
                        .padding(.horizontal)
                    Text("\(song.artist) - \(song.album)")
                        .font(.caption).bold()
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                } else {
                    Text("No Song Selected").font(.subheadline).padding(.top, 10)
                    Text("Select a song from your library").font(.footnote).foregroundColor(.gray)
                }

                Spacer()

                HStack(spacing: 20) {
                    Button(action: { musicPlayer.previousTrack() }) {
                        Image(systemName: "backward.fill").font(.title3)
                    }
                    .frame(width: 35, height: 35)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
                    .disabled(musicPlayer.currentSong == nil)

                    Button(action: { musicPlayer.playPause() }) {
                        Image(systemName: musicPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                            .padding(.leading, musicPlayer.isPlaying ? 0 : 2)
                    }
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
                    .disabled(musicPlayer.currentSong == nil)

                    Button(action: { musicPlayer.nextTrack() }) {
                        Image(systemName: "forward.fill").font(.title3)
                    }
                    .frame(width: 35, height: 35)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
                    .disabled(musicPlayer.currentSong == nil)
                }
                .padding(.bottom)
            }
            .padding(.vertical)
            
            // ADDED: Toast message view for success notifications
            if toastMessage != nil {
                VStack {
                    Spacer()
                    Text(toastMessage!)
                        .padding()
                        .background(.thinMaterial)
                        .foregroundColor(.primary)
                        .cornerRadius(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation {
                            toastMessage = nil
                        }
                    }
                }
                .zIndex(1)
            }
        }
        .focusable()
        // UPDATED: The crown now binds to an intermediate state variable.
        .digitalCrownRotation($crownRotation, from: 0.0, through: 1.0, by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear {
            // Initialize the crown's position based on the inverted volume.
            crownRotation = 1.0 - Double(musicPlayer.volume)
        }
        // UPDATED: This observer now calculates the inverted volume before setting it.
        .onChange(of: crownRotation) { oldValue, newValue in
            let newVolume = 1.0 - newValue
            musicPlayer.setVolume(Float(newVolume))
        }
        // ADDED: An extra observer to keep the crown position in sync.
        .onChange(of: musicPlayer.volume) { _, newVolume in
            crownRotation = 1.0 - Double(newVolume)
        }
        .task(id: musicPlayer.currentSong?.id) {
            await updateBackgroundColor()
        }
        .navigationTitle("Now Playing")
        // UPDATED: Overflow menu button now shows the menu.
        .overlay(alignment: .topTrailing) {
            if musicPlayer.currentSong != nil {
                Button(action: { showOptionsMenu = true }) {
                    Image(systemName: "ellipsis")
                        .font(.body)
                }
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.15))
                .clipShape(Circle())
                .padding(.trailing)
            }
        }
        // UPDATED: The confirmation dialog now includes navigation options.
        .confirmationDialog("Actions", isPresented: $showOptionsMenu, titleVisibility: .hidden) {
            Button("Add to Playlist") {
                songForPlaylistAction = musicPlayer.currentSong
            }
            
            // ADDED: Conditional "Go to" buttons for album and artist.
            if let song = musicPlayer.currentSong, let artist = libraryManager.artists.first(where: { $0.name == song.artist }) {
                if let album = artist.albums.first(where: { $0.name == song.album }) {
                    Button("Go to Album") {
                        // UPDATED: Call the new navigation method
                        viewRouter.navigateTo(artist: artist, album: album)
                    }
                }
                Button("Go to Artist") {
                    // UPDATED: Call the new navigation method
                    viewRouter.navigateTo(artist: artist, album: nil)
                }
            }
        }
        // UPDATED: The sheet is now triggered by an identifiable item for better reliability.
        .sheet(item: $songForPlaylistAction) { song in
            PlayerAddToPlaylistView(song: song) { playlistName in
                withAnimation {
                    toastMessage = "Added to \"\(playlistName)\""
                }
            }
        }
    }

    private func updateBackgroundColor() async {
        guard let currentSong = musicPlayer.currentSong else {
            backgroundColors = [.black, .gray.opacity(0.5)]
            return
        }

        // Perform the image processing in a background task.
        let colors = await Task.detached(priority: .background) { () -> [Color] in
            guard let artworkData = try? await getArtworkData(for: currentSong),
                  let uiImage = UIImage(data: artworkData) else {
                return [.black, .gray.opacity(0.5)]
            }
            return uiImage.gradientColors
        }.value
        
        self.backgroundColors = colors
    }
    
    // Helper function to fetch artwork data for the background task.
    private func getArtworkData(for song: Song) async throws -> Data? {
        let asset = AVURLAsset(url: song.path)
        let metadata = try await asset.load(.metadata)
        let artworkItems = AVMetadataItem.metadataItems(from: metadata, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common)
        
        if let artworkItem = artworkItems.first {
            return try await artworkItem.load(.dataValue)
        }
        return nil
    }
}

// MARK: - Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
