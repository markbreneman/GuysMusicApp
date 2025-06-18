import os
import json
import uuid
import unicodedata

def create_music_index(root_folder, output_file='index.json'):
    """
    Recursively scans a directory for music files and creates a JSON index.
    It normalizes filenames to handle special characters and accents consistently.

    Args:
        root_folder (str): The path to the main music folder.
        output_file (str): The name of the JSON file to create.
    """
    all_albums = {}

    print(f"Starting scan in: {root_folder}")

    # Walk through the directory structure
    for artist_name in os.listdir(root_folder):
        artist_path = os.path.join(root_folder, artist_name)
        # Check if the path is a directory and not a hidden file
        if os.path.isdir(artist_path) and not artist_name.startswith('.'):
            for album_name in os.listdir(artist_path):
                album_path = os.path.join(artist_path, album_name)
                if os.path.isdir(album_path) and not album_name.startswith('.'):
                    
                    # --- FIXED: Normalize names to handle special characters ---
                    artist_name_norm = unicodedata.normalize('NFC', artist_name)
                    album_name_norm = unicodedata.normalize('NFC', album_name)

                    album_key = f"{artist_name_norm}-{album_name_norm}"
                    if album_key not in all_albums:
                        all_albums[album_key] = {
                            "name": album_name_norm,
                            "artist": artist_name_norm,
                            "songs": []
                        }

                    for song_filename in os.listdir(album_path):
                        # Simple check for audio files
                        if song_filename.lower().endswith(('.mp3', '.m4a', '.flac', '.wav')):
                            song_filename_norm = unicodedata.normalize('NFC', song_filename)
                            song_title = os.path.splitext(song_filename_norm)[0]
                            
                            # Use forward slashes for a consistent URL-friendly path
                            relative_path = f"{artist_name_norm}/{album_name_norm}/{song_filename_norm}"

                            song_entry = {
                                "id": str(uuid.uuid4()),
                                "title": song_title,
                                "artist": artist_name_norm,
                                "album": album_name_norm,
                                "relativePath": relative_path
                            }
                            
                            all_albums[album_key]["songs"].append(song_entry)

    # Convert the dictionary of albums to a list
    album_list = list(all_albums.values())

    # Write the JSON data to the output file
    try:
        with open(output_file, 'w', encoding='utf-8') as f:
            json.dump(album_list, f, ensure_ascii=False, indent=4)
        print(f"Successfully created '{output_file}' with {len(album_list)} albums.")
    except IOError as e:
        print(f"Error writing to file: {e}")

if __name__ == '__main__':
    # --- IMPORTANT ---
    # Change this path to the root directory of your music collection.
    # This is the directory that your Python SimpleHTTPServer will serve.
    # For example: '/Users/yourname/Music/MyMusicForWatch'
    music_directory = './Music' # Assumes a 'Music' folder in the same directory as the script

    # Check if the directory exists before running
    if os.path.isdir(music_directory):
        create_music_index(music_directory, os.path.join(music_directory, 'index.json'))
    else:
        print(f"Error: The specified directory does not exist: '{music_directory}'")
        print("Please create it and place your music inside, or change the 'music_directory' variable.")

