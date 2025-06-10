import SwiftUI
import AVFoundation
import MediaPlayer
// REMOVED: import CoreImage is no longer needed.
import CoreGraphics // ADDED: For low-level image processing.

// MARK: - Navigation State
enum Tab {
    case player, library, playlists
}

class ViewRouter: ObservableObject {
    @Published var currentTab: Tab = .library
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
        // This assumes the "Music" directory is in the bundle's resource path
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
// ADDED: An extension to clean up song titles by removing track numbers.
extension String {
    /// Removes leading track numbers (e.g., "01. ", "02 - ") from a string using regular expressions.
    func removingTrackNumber() -> String {
        // This pattern looks for one or more digits at the start of the string,
        // followed by optional whitespace and a separator (like '.', '-', or just space).
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
                    // UPDATED: The song title is now cleaned to remove any track number prefixes.
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
    
    private func play() {
        audioPlayer?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    private func pause() {
        audioPlayer?.pause()
        isPlaying = false
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
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var musicPlayer = MusicPlayerManager()
    @StateObject private var libraryManager = MusicLibraryManager()
    @StateObject private var playlistManager = PlaylistManager()
    @StateObject private var viewRouter = ViewRouter()

    var body: some View {
        TabView(selection: $viewRouter.currentTab) {
            PlayerView()
                .tabItem {
                    VStack {
                        Image(systemName: "play.circle.fill")
                            .font(.subheadline)
                        Text("Player")
                            .font(.caption2)
                    }
                }
                .tag(Tab.player)
            
            LibraryView()
                 .tabItem {
                    VStack {
                        Image(systemName: "music.note.list")
                            .font(.subheadline)
                        Text("Library")
                            .font(.caption2)
                    }
                 }
                 .tag(Tab.library)

            PlaylistsView()
                .tabItem {
                    VStack {
                        Image(systemName: "music.note")
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
    }
}

// MARK: - Library View
struct LibraryView: View {
    @EnvironmentObject var libraryManager: MusicLibraryManager

    var body: some View {
        NavigationView {
            List {
                ForEach(libraryManager.artists) { artist in
                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                        Text(artist.name)
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

// MARK: - Artist and Album Detail Views
struct ArtistDetailView: View {
    let artist: Artist
    
    var body: some View {
        List {
            ForEach(artist.albums) { album in
                NavigationLink(destination: AlbumDetailView(album: album)) {
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
        .navigationTitle(album.name)
        .sheet(item: $songToAddToPlaylist) { song in
            AddToPlaylistView(song: song)
        }
    }
}

// MARK: - Playlist Views
struct PlaylistsView: View {
    @EnvironmentObject var playlistManager: PlaylistManager
    @State private var isShowingCreateSheet = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationView {
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
                VStack {
                    Text("New Playlist").font(.headline).padding()
                    TextField("Playlist Name", text: $newPlaylistName)
                        .padding()
                    HStack {
                        Button("Cancel") {
                            isShowingCreateSheet = false
                            newPlaylistName = ""
                        }
                        Spacer()
                        Button("Create") {
                            if !newPlaylistName.isEmpty {
                                playlistManager.createPlaylist(name: newPlaylistName)
                                newPlaylistName = ""
                                isShowingCreateSheet = false
                            }
                        }
                    }
                    .padding()
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

struct AddToPlaylistView: View {
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var playlistManager: PlaylistManager
    let song: Song

    var body: some View {
        NavigationView {
            List {
                ForEach(playlistManager.playlists) { playlist in
                    Button(action: {
                        playlistManager.addSong(song, to: playlist.id)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text(playlist.name)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Artwork View
struct ArtworkView: View {
    let song: Song?
    @State private var artworkData: Data?
    
    var body: some View {
        Group {
            if let data = artworkData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 50))
                    .foregroundColor(.gray.opacity(0.5))
            }
        }
        .frame(width: 80, height: 80)
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


// MARK: - Player View
struct PlayerView: View {
    @EnvironmentObject var musicPlayer: MusicPlayerManager
    @State private var volume: Double = 0.5
    @State private var backgroundColors: [Color] = [.black, .gray.opacity(0.5)]

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors, startPoint: .top, endPoint: .bottom)
                .animation(.spring(), value: backgroundColors)
                .ignoresSafeArea()

            VStack {
                ArtworkView(song: musicPlayer.currentSong)
                
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
        }
        .focusable()
        .digitalCrownRotation($volume, from: 0.0, through: 1.0, by: 0.05, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear {
            volume = Double(musicPlayer.volume)
        }
        // UPDATED: The 'onChange' modifier now uses the modern two-parameter
        // closure '(oldValue, newValue)' to resolve the deprecation warning.
        .onChange(of: volume) { oldValue, newValue in
            musicPlayer.setVolume(Float(newValue))
        }
        .task(id: musicPlayer.currentSong?.id) {
            await updateBackgroundColor()
        }
        .navigationTitle("Now Playing")
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
