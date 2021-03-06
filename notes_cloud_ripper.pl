#   Apple Cloud Notes Parser is a short script to pull gzipped data from an iCloud Notes database.
#   Copyright (C) 2017 Jon Baumann

#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.

#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.

use DBI;
use File::Copy;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use Getopt::Long qw(:config no_auto_abbrev);

# Set up initial variables
my $original_file = "NoteStore.sqlite";
my $leave_dirty = 0;
my $help = 0;
my %notes_to_store;

# Read in options
GetOptions('file=s' => \$original_file,
           'dirty' => \$leave_dirty,
           'help' => \$help);

# Ensure we have a file to work on
if($help || !$original_file) {
  print_usage();
  exit();
}

if(! -f $original_file) {
  die "File $original_file does not exist\n";
}

# Make sure we don't mess up our original
my $output_db_file = $original_file;
$output_db_file =~ s/.sqlite/.decompressed.sqlite/;
copy($original_file, $output_db_file);
print "Copying original file to preserve it, working from $output_db_file\n";

# Set up database connection
my $dsn = "DBI:SQLite:dbname=$output_db_file";
my $dbh = DBI->connect($dsn) or die "Cannot open $output_db_file\n";

# Define query to pull the note identifier and the note data from ZICNOTEDATA
my $query = "SELECT Z_PK, ZDATA FROM ZICNOTEDATA;";
my $query_handler = $dbh->prepare($query);
my $return_value = $query_handler->execute();

print "Extracting original notes\n";

# Iterate over results
while(my @row = $query_handler->fetchrow_array()) {
  # Get results
  my $z_pk = $row[0];
  my $binary = $row[1];

  if($leave_dirty) {
    # Create filename
    my $output_file = "note_".$z_pk.".blob.gz";
    print "\tSaving note $z_pk\n";

    # Save results off to show our work
    open(OUTPUT, ">$output_file");
    binmode(OUTPUT);
    print OUTPUT $binary;
    close(OUTPUT);
  }
  my $gunzip_output;
  gunzip(\$binary => \$gunzip_output);
  $notes_to_store{$z_pk} = $gunzip_output;
}

if($leave_dirty) {
  # Gunzip all saved blobs
  print "Extracting gzipped notes\n";
  gunzip '<./note_*.blob.gz>' => '<./note_#1.blob>' or die "Error gunzipping: $GunzipError\n";
}

# Create decompressed data column
print "Modifying table to hold our content\n";
my $decompressed_text_column = "ZDECOMPRESSEDTEXT";
my $column_addition_query = "ALTER TABLE ZICNOTEDATA ADD COLUMN $decompressed_text_column TEXT";
my $column_addition_handler = $dbh->prepare($column_addition_query);
$column_addition_handler->execute();
print "\tAdded column $decompressed_text_column to store extracted text\n";

print "Parsing and updating Notes\n";

foreach $note_number (sort(keys(%notes_to_store))) {
  $binary = $notes_to_store{$note_number};
  print "\tWorking on note $note_number\n";

  # Valid notes appear to start with 08 00 12
  if(is_valid_note($binary)) {
    # Parse out any plaintext at the start
    my $decompressed_text;
    $decompressed_text = get_plaintext($binary);

    # Create update query
    my $update_query = "UPDATE ZICNOTEDATA SET ZDATA=?,$decompressed_text_column=? WHERE Z_PK=?";
    my $query_handler = $dbh->prepare($update_query);
    $query_handler->execute($binary, $decompressed_text, $note_number);
    print "\t\tUpdated $note_number with decompressed data\n";
  } else {
    print "\t\tSkipping note $note_number as it appears to be encrypted or otherwise not parsed correctly\n";
  }
}

# Close database handle
$dbh->disconnect();


####################
# Functions Follow #
####################

sub get_plaintext {
  my $input_string = @_[0];
  my $plain_text;

  # Find the apparent magic string 08 00 10 00 1a
  $pointer = index($input_string, "\x08\x00\x10\x00\x1a");

  # Find the next byte after 0x12
  $pointer = index($input_string, "\x12", $pointer + 1) + 1;

  # Read the next byte as the length of plain text
  $string_length = ord substr($input_string, $pointer, 1);

  # Fetch the plain text
  $plain_text = substr($input_string, $pointer + 1, $string_length);
  return $plain_text;
}

# Function to check the first three bytes of decompressed data to see if it is a real note
sub is_valid_note {
  my $input_string = @_[0];
  if(substr($input_string, 0, 3) eq "\x08\x00\x12") {
    return 1;
  } else {
    return 0;
  }
}

# Function to print the usage
sub print_usage {
  print "Apple Cloud Notes Parser - Copyright (C) 2017 Jon Baumann, Ciofeca Forensics\n";
  print "\tThis program comes with ABSOLUTELY NO WARRANTY;\n";
  print "\tThis is free software, and you are welcome to redistribute it under certain conditions.\n";
  print "\tSee http://www.gnu.org/licenses/\n";
  print "Usage:\n";
  print "\tperl notes_cloud_ripper.pl [--file=<path to NoteStore.sqlite>] [--dirty] [--help]\n\n";
  print "Options:\n";
  print "\t--file=<path>: Identifies the NoteStore.sqlite file to workon\n";
  print "\t--dirty: If set, will save .gz and .blob files, letting the user play with them\n";
  print "\t--help: Prints this message\n\n";
  print "Examples:\n";
  print "\tperl notes_cloud_ripper.pl\n";
  print "\tperl notes_cloud_ripper.pl --file=\"C:\\Users\\Test\\Desktop\\NoteStore.sqlite\"\n";
  return 1;
}
